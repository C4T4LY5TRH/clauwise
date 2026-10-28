import Foundation

enum WindowKey {
    static let fiveHour = "five_hour"
    static let sevenDay  = "seven_day"
    static let extraUsage = "extra_usage"
}

struct PaceSample: Codable {
    let timestamp: Date
    let utilization: Double  // 0–100
}

struct WindowPace {
    let projectedAtReset: Double  // % projected at window reset
    let secondsToFull: Double     // seconds until 100% at current rate
    let onPaceToExhaust: Bool     // projectedAtReset > 100
    let ratePerHour: Double       // %/hr — for display alongside projection
    let secondsToWarning: Double? // seconds until warning threshold; nil if already above or won't hit before reset
}

enum PaceResult {
    case noData      // < 2 samples — still warming up
    case idle        // 2+ samples but rate ≤ 0 — not actively using Claude
    case nearReset   // < 10 min until reset — suppress line
    case active(WindowPace)
}

final class PaceTracker {
    private var buffers: [String: [PaceSample]] = [:]
    private let maxSamples = 10

    init() {
        // Seed from the *whole* persisted sample history, not just the single most recent
        // sample — a relaunch (app update, crash recovery, or just quitting and reopening)
        // would collapse the buffer back down to 1 point, throwing away up to ~25 minutes
        // of real trend and forcing pace() back through .noData/.idle for several more poll
        // cycles even during genuinely active, ongoing usage.
        for key in [WindowKey.fiveHour, WindowKey.sevenDay] {
            let stored = AppSettings.shared.storedPaceSamples(forKey: key)
            guard !stored.isEmpty else { continue }
            // Without a stored reset boundary we can't tell if these samples are from a prior
            // window — skip seeding rather than risk a misleading negative-slope idle result
            // from mixing pre/post-reset data.
            guard let resetAt = AppSettings.shared.storedPaceWindowResetAt(forKey: key) else { continue }
            // If the stored window has already rolled over, keep only samples taken after
            // that boundary (rather than discarding the whole batch) — a relaunch landing
            // just after a reset can still usefully seed from the handful of post-reset
            // samples already recorded before it quit.
            let seeded = resetAt <= Date() ? stored.filter { $0.timestamp >= resetAt } : stored
            guard !seeded.isEmpty else { continue }
            // pace() assumes buf.first/buf.last are the oldest/newest samples by array
            // position (it never re-sorts) — true in practice only because record() always
            // appends in chronological order. Sort explicitly here rather than lean on that
            // as an unstated invariant of the persisted JSON; a chronologically-ordered
            // array sorts to a no-op, so this costs nothing in the normal case.
            buffers[key] = seeded.sorted { $0.timestamp < $1.timestamp }
        }
    }

    @discardableResult
    func record(windowKey: String, utilization: Double, resetsAt: Date?) -> Bool {
        var buf = buffers[windowKey] ?? []
        var rolledOver = false
        if let last = buf.last {
            // A window reset mid-runtime (not just at process start) must flush the buffer —
            // otherwise pre-reset and post-reset samples mix into a false negative slope (.idle)
            // for up to ~9 poll cycles. resetsAt is the primary signal; a sharp utilization drop
            // is a fallback for when the API returns a nil resets_at right on the boundary poll.
            let rolledOverByResetDate: Bool = {
                guard let previousResetAt = AppSettings.shared.storedPaceWindowResetAt(forKey: windowKey) else { return false }
                return previousResetAt <= Date() && last.timestamp < previousResetAt
            }()
            let rolledOverBySharpDrop = utilization < last.utilization - 20
            if rolledOverByResetDate || rolledOverBySharpDrop {
                buf = []
                rolledOver = true
            }
        }
        let sample = PaceSample(timestamp: Date(), utilization: utilization)
        buf.append(sample)
        if buf.count > maxSamples { buf.removeFirst() }
        buffers[windowKey] = buf
        // Persist the whole (already-trimmed-to-maxSamples) buffer, not just the newest
        // sample — see the seeding comment in init() for why a single persisted point
        // isn't enough to survive a relaunch without losing real trend data.
        AppSettings.shared.setStoredPaceSamples(buf, forKey: windowKey)
        if let d = resetsAt {
            AppSettings.shared.setStoredPaceWindowResetAt(d, forKey: windowKey)
        }
        return rolledOver
    }

    func pace(forKey key: String, currentUtil: Double, secondsUntilReset: Double) -> PaceResult {
        guard secondsUntilReset > 10 * 60 else { return .nearReset }
        guard let buf = buffers[key], buf.count >= 2 else { return .noData }
        // Blend the last ~10 minutes of samples with the full ~25-minute buffer rather than
        // using the recent slice alone: recent-only made the projection swing wildly on a short
        // burst (extrapolated across the whole remaining window) and collapse to .idle the
        // instant usage paused, with nothing to damp either swing.
        let fullElapsed = buf.last!.timestamp.timeIntervalSince(buf.first!.timestamp)
        guard fullElapsed > 0 else { return .noData }
        let fullRate = (buf.last!.utilization - buf.first!.utilization) / fullElapsed  // %/sec

        let recentWindow: TimeInterval = 10 * 60
        let cutoff = buf.last!.timestamp.addingTimeInterval(-recentWindow)
        let recent = buf.filter { $0.timestamp >= cutoff }
        let recentRate: Double? = {
            guard recent.count >= 2 else { return nil }
            let elapsed = recent.last!.timestamp.timeIntervalSince(recent.first!.timestamp)
            guard elapsed > 0 else { return nil }
            return (recent.last!.utilization - recent.first!.utilization) / elapsed
        }()

        let rate = recentRate.map { 0.7 * $0 + 0.3 * fullRate } ?? fullRate
        guard rate > 0 else { return .idle }
        let projected = currentUtil + rate * secondsUntilReset
        let toFull = (100.0 - currentUtil) / rate
        let ratePerHour = rate * 3600
        let warningThreshold = AppSettings.shared.warningThreshold
        let secondsToWarning: Double?
        if currentUtil < warningThreshold {
            let s = (warningThreshold - currentUtil) / rate
            secondsToWarning = s < secondsUntilReset ? s : nil
        } else {
            secondsToWarning = nil
        }
        return .active(WindowPace(projectedAtReset: projected, secondsToFull: toFull, onPaceToExhaust: projected > 100, ratePerHour: ratePerHour, secondsToWarning: secondsToWarning))
    }
}
