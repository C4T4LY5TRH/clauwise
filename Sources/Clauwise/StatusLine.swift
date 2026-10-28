import Foundation

// MARK: - `Clauwise statusline` subcommand
//
// Invoked by Claude Code CLI itself (wired via ~/.claude/settings.json's
// statusLine key, see StatusLineInstaller.swift) — reads the JSON Claude Code
// pipes on stdin (cwd, active model) plus the usage.json snapshot this app
// already exports on every poll, and prints one formatted line to stdout.
// Runs and exits before any AppKit/menu-bar code — see main.swift.

enum StatusLine {
    struct Input: Decodable {
        struct ModelInfo: Decodable { let id: String? }
        let cwd: String?
        let model: ModelInfo?
    }

    static func run() {
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let input = try? JSONDecoder().decode(Input.self, from: stdinData)

        let snapshot: ExportSnapshot? = {
            guard let data = try? Data(contentsOf: UsageExport.fileURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ExportSnapshot.self, from: data)
        }()

        print(formatLine(cwd: input?.cwd.map(shortenHome), modelId: input?.model?.id, snapshot: snapshot))
    }

    static func formatLine(cwd: String?, modelId: String?, snapshot: ExportSnapshot?) -> String {
        var parts: [String] = []
        if let five = snapshot?.fiveHourPercent { parts.append("5h: \(Int(five))%") }
        if let seven = snapshot?.sevenDayPercent { parts.append("7d: \(Int(seven))%") }
        if let modelId, !modelId.isEmpty { parts.append(modelId) }
        if let cwd, !cwd.isEmpty { parts.append(cwd) }
        return parts.joined(separator: "  ")
    }

    private static func shortenHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
