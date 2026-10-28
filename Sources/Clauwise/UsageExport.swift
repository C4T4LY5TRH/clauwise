import Foundation

// MARK: - JSON export for external tools (shell prompts, statuslines, etc.)
//
// Written atomically to ~/.clauwise/usage.json after every
// successful refresh() so other processes never observe a half-written file.

struct ExportSnapshot: Codable {
    let fetchedAt: Date
    let fiveHourPercent: Double?
    let fiveHourResetsAt: String?
    let sevenDayPercent: Double?
    let sevenDayResetsAt: String?
    let extraUsageEnabled: Bool?
    let extraUsagePercent: Double?
    let tokensTodayByModel: [String: Int]
    let activeModel: String?
}

enum UsageExport {
    static let directory = URL(fileURLWithPath: NSString(string: "~/.clauwise").expandingTildeInPath)
    static let fileURL = directory.appendingPathComponent("usage.json")

    static func write(_ usage: UsageResponse, summary: TodayUsageSummary) {
        let snapshot = ExportSnapshot(
            fetchedAt: Date(),
            fiveHourPercent: usage.five_hour?.utilization,
            fiveHourResetsAt: usage.five_hour?.resets_at,
            sevenDayPercent: usage.seven_day?.utilization,
            sevenDayResetsAt: usage.seven_day?.resets_at,
            extraUsageEnabled: usage.extra_usage?.is_enabled,
            extraUsagePercent: usage.extra_usage?.utilization,
            tokensTodayByModel: summary.totalsByModel.mapValues { $0.totalTokens },
            activeModel: summary.activeModel
        )

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)

            let tmpURL = directory.appendingPathComponent("usage.json.tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            log("UsageExport: write failed: \(error)")
        }
    }
}
