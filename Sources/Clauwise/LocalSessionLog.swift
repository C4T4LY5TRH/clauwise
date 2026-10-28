import Foundation

// MARK: - Local Claude Code session log parsing
//
// Claude Code CLI writes one JSONL file per session under
// ~/.claude/projects/<project-slug>/<session-uuid>.jsonl. This reader is the
// data source for two CLI-only features: today's token usage totals, and the
// "currently active model" indicator. It cannot see web/desktop app usage —
// only local CLI sessions are visible on disk.

struct LogLineUsage: Codable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
}

struct LogLineMessage: Codable {
    let model: String?
    let usage: LogLineUsage?
}

struct LogLine: Codable {
    let type: String?
    let timestamp: String?
    let message: LogLineMessage?
    let isSidechain: Bool?
}

struct ModelTokenTotals {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }

    // Fraction of prompt-processing tokens (fresh input + cache write + cache
    // read) actually served from cache rather than written fresh — the ratio
    // that gives the raw read/created counts a baseline to compare against.
    // nil when there's no prompt-processing volume at all to take a ratio of.
    var cacheHitRate: Double? {
        let promptTokens = inputTokens + cacheCreationTokens + cacheReadTokens
        guard promptTokens > 0 else { return nil }
        return Double(cacheReadTokens) / Double(promptTokens) * 100
    }
}

struct TodayUsageSummary {
    var totalsByModel: [String: ModelTokenTotals] = [:]
    var activeModel: String?
    var activeModelTimestamp: Date?
}

final class LocalSessionLogReader {
    let projectsDir: URL

    init(projectsDir: URL = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath)) {
        self.projectsDir = projectsDir
    }

    /// All session JSONL files, excluding subagent transcripts (which live
    /// under a `subagents/` path component and don't represent the primary
    /// interactive session).
    func findAllSessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if url.pathComponents.contains("subagents") { continue }
            result.append(url)
        }
        return result
    }

    func mostRecentlyModifiedFile(among files: [URL]) -> URL? {
        files.max { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lDate < rDate
        }
    }

    private func parseLines(of file: URL) -> [LogLine] {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var lines: [LogLine] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = rawLine.data(using: .utf8) else { continue }
            if let parsed = try? JSONDecoder().decode(LogLine.self, from: lineData) {
                lines.append(parsed)
            }
        }
        return lines
    }

    func summarizeToday(now: Date = Date()) -> TodayUsageSummary {
        var summary = TodayUsageSummary()
        let files = findAllSessionFiles()

        for file in files {
            for line in parseLines(of: file) {
                guard let usage = line.message?.usage, let model = line.message?.model,
                      let tsString = line.timestamp, let ts = parseISO(tsString) else { continue }
                guard Calendar.current.isDate(ts, inSameDayAs: now) else { continue }

                var totals = summary.totalsByModel[model, default: ModelTokenTotals()]
                totals.inputTokens += usage.input_tokens ?? 0
                totals.outputTokens += usage.output_tokens ?? 0
                totals.cacheCreationTokens += usage.cache_creation_input_tokens ?? 0
                totals.cacheReadTokens += usage.cache_read_input_tokens ?? 0
                summary.totalsByModel[model] = totals
            }
        }

        if let activeFile = mostRecentlyModifiedFile(among: files) {
            for line in parseLines(of: activeFile).reversed() {
                guard let model = line.message?.model,
                      let tsString = line.timestamp, let ts = parseISO(tsString) else { continue }
                summary.activeModel = model
                summary.activeModelTimestamp = ts
                break
            }
        }

        return summary
    }
}
