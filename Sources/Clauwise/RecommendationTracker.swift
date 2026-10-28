import Foundation

// Recommendation.swift's `recommendation(...)` is a stateless pure function recomputed every
// poll — without memory, a rank drop (e.g. caution -> goodTime) applies the instant the recent
// pace goes idle, even seconds after a real warning. This wrapper adds hysteresis: upgrades
// (worse news) apply immediately, but a downgrade only sticks once it's been the freshly
// computed result continuously for `dwell`, so a brief idle blip can't flip the message back to
// "good time" within minutes of a genuine caution/exhaustion warning.
final class RecommendationTracker {
    private var pendingRank: Int = 0
    private var pendingRec: Recommendation?
    private var candidateSince: Date?
    private let dwell: TimeInterval = 8 * 60   // ~3 poll cycles at 150s

    func apply(rank: Int, rec: Recommendation?) -> Recommendation? {
        if rank >= pendingRank {
            pendingRank = rank
            pendingRec = rec
            candidateSince = nil
            return pendingRec
        }
        if candidateSince == nil { candidateSince = Date() }
        if let since = candidateSince, Date().timeIntervalSince(since) >= dwell {
            pendingRank = rank
            pendingRec = rec
            candidateSince = nil
        }
        return pendingRec
    }

    func reset() {
        pendingRank = 0
        pendingRec = nil
        candidateSince = nil
    }
}
