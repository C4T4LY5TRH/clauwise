import Foundation

// MARK: - Recommendation-engine accuracy telemetry
//
// Ground-truth dataset for validating Recommendation.swift/PaceTracker.swift's
// hand-picked constants (imminentThreshold, dwell, the accumulation multiplier,
// blend weights, ...) against real outcomes instead of leaving them as untested
// guesses indefinitely.
//
// One JSONL row is appended per successful refresh() poll (never per menu
// render — rebuildMenu()/render() are called far more often than real polls,
// e.g. once per menu open via refreshLocalSummary(), which would badly
// duplicate-weight a naive per-render hook). Deliberately independent of
// AppSettings.showPaceIndicator and RecommendationTracker's UI-level
// hysteresis — this logs the raw instantaneous recommendation() computation,
// since the point is validating the underlying math, not replaying exactly
// what the menu happened to show at that instant.
//
// No new API call is needed or added: every field logged here already flows
// through the existing /api/oauth/usage response (UsageAPI.swift's
// UsageResponse.five_hour/seven_day) that PaceTracker/Recommendation.swift
// already consume — confirmed by inspection before writing this file.
//
// Scoring predictions against outcomes (did a window's utilization actually
// reach ~100% before its own resets_at?) is deliberately NOT done here — left
// to future offline analysis of the log, joining rows by resets_at, since
// every row already carries both windows' current utilization and resets_at.
// No in-app viewer/UI for this data exists yet either; this pass only appends
// the raw dataset.

struct RecommendationLogEntry: Codable {
    let timestamp: Date
    let fiveUtil: Double?
    let fiveResetsAt: Date?
    let sevenUtil: Double?
    let sevenResetsAt: Date?
    let rank: Int
    let recommendation: String // human-readable Recommendation case, or "none"
}

enum RecommendationTelemetry {
    // Reuses UsageExport's directory rather than re-deriving the path — same
    // ~/.clauwise/ external-data convention as usage.json.
    static let logURL = UsageExport.directory.appendingPathComponent("recommendation-log.jsonl")

    // Kept short enough that even a full-file prune rewrite (see pruneIfNeeded)
    // stays cheap, but long enough to span several weekly (7d) cycles for
    // meaningful later analysis.
    static let maxAge: TimeInterval = 90 * 24 * 3600
    // Prune is a full read+decode+rewrite of the file — cheap at this app's
    // realistic file sizes (~13MB steady-state at 90 days retention / 150s
    // poll cadence) but there's no reason to pay even that cost on every
    // single poll. Gated to at most once/24h via AppSettings, mirroring the
    // minRefreshInterval/minLocalSummaryInterval throttle-gate pattern
    // already used elsewhere in this codebase.
    private static let pruneCheckInterval: TimeInterval = 24 * 3600

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // Call once per successful refresh() poll, after PaceTracker.record() has
    // been called for both windows so the pace computed here reflects this
    // poll's fresh sample (matches how render()'s own fivePace/sevenPace are
    // computed, just independent of the showPaceIndicator toggle).
    static func record(usage: UsageResponse, paceTracker: PaceTracker) {
        guard AppSettings.shared.recordUsageHistory else { return }
        let fiveResetDate = usage.five_hour?.resets_at.flatMap { parseISO($0) }
        let sevenResetDate = usage.seven_day?.resets_at.flatMap { parseISO($0) }
        let fivePace: PaceResult? = {
            guard let f = usage.five_hour?.utilization, let d = fiveResetDate else { return nil }
            return paceTracker.pace(forKey: WindowKey.fiveHour, currentUtil: f, secondsUntilReset: d.timeIntervalSinceNow)
        }()
        let sevenPace: PaceResult? = {
            guard let s = usage.seven_day?.utilization, let d = sevenResetDate else { return nil }
            return paceTracker.pace(forKey: WindowKey.sevenDay, currentUtil: s, secondsUntilReset: d.timeIntervalSinceNow)
        }()
        let computed = recommendation(
            fiveUtil: usage.five_hour?.utilization, fivePace: fivePace, fiveSecondsUntilReset: fiveResetDate?.timeIntervalSinceNow,
            sevenUtil: usage.seven_day?.utilization, sevenPace: sevenPace, sevenSecondsUntilReset: sevenResetDate?.timeIntervalSinceNow,
            warningThreshold: AppSettings.shared.warningThreshold, criticalThreshold: AppSettings.shared.criticalThreshold
        )
        let entry = RecommendationLogEntry(
            timestamp: Date(),
            fiveUtil: usage.five_hour?.utilization, fiveResetsAt: fiveResetDate,
            sevenUtil: usage.seven_day?.utilization, sevenResetsAt: sevenResetDate,
            rank: computed.rank, recommendation: describe(computed.rec)
        )
        append(entry)

        let last = AppSettings.shared.recommendationLogLastPrunedAt
        if last == nil || Date().timeIntervalSince(last!) >= pruneCheckInterval {
            AppSettings.shared.recommendationLogLastPrunedAt = Date()
            Task.detached(priority: .utility) {
                pruneIfNeeded()
            }
        }
    }

    static func describe(_ rec: Recommendation?) -> String {
        switch rec {
        case .critical(let label, let pct): return "critical(\(label),\(pct)%)"
        case .badTimeToStart(let label, let eta): return "badTimeToStart(\(label),eta=\(eta))"
        case .caution(let label): return "caution(\(label))"
        case .goodTime: return "goodTime"
        case nil: return "none"
        }
    }

    // `to:` is injectable (defaults to the real logURL) purely for standalone
    // testing against a scratch file, mirroring pruneIfNeeded's own `url:`
    // parameter below — production call sites never pass it explicitly.
    static func append(_ entry: RecommendationLogEntry, to url: URL = logURL) {
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(lineData)
        } catch {
            log("RecommendationTelemetry: append failed: \(error)")
        }
    }

    // Rewrites the file dropping rows older than maxAge. Not @MainActor —
    // called via Task.detached from record() so the (at most once/24h) full
    // read+decode+rewrite never blocks refresh()'s @MainActor Task.
    // Accepted, extremely-low-probability race (no file locking, same
    // rationale as StatusLineInstaller's settings.json read-modify-write):
    // if a concurrent
    // append() lands between this function's read and its final
    // replaceItemAt, that append is lost — the rewrite is based on a
    // snapshot taken before it. In practice this needs a poll to land
    // within the sub-second prune window, against a 150s poll cadence and a
    // prune that runs at most once/24h; not engineered around, since locking
    // would add more risk than it removes.
    static func pruneIfNeeded(url: URL = Self.logURL, maxAge: TimeInterval = Self.maxAge, now: Date = Date()) {
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        // Rows are appended in chronological order, so the oldest is always
        // first — check just that one line before deciding whether a full
        // rewrite is even needed.
        guard let firstEntry = decodeLine(lines[0]), firstEntry.timestamp < cutoff else { return }
        let kept = lines.filter { line in
            guard let entry = decodeLine(line) else { return true } // keep unparseable lines rather than silently drop data
            return entry.timestamp >= cutoff
        }
        let rewritten = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        do {
            let tmpURL = url.appendingPathExtension("tmp")
            try rewritten.data(using: .utf8)?.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } catch {
            log("RecommendationTelemetry: prune failed: \(error)")
        }
    }

    private static func decodeLine(_ line: Substring) -> RecommendationLogEntry? {
        try? decoder.decode(RecommendationLogEntry.self, from: Data(line.utf8))
    }
}
