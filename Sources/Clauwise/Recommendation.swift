import Foundation

// "Bad time to start X" recommendation engine: turns the raw pace/utilization
// data already computed by PaceTracker into a single plain-language line —
// the one thing worth reading before starting a big task, instead of making
// people mentally combine %, rate, and time-to-reset themselves.
// Each window (5h, 7d) is scored independently by severity() below, in strict
// priority order (first match wins, not "whichever threshold is crossed"):
// 1. Critical (rank 3): util >= criticalThreshold AND reset isn't imminent
//    (<=30min out) — a high percentage stops being urgent once the window is
//    about to hand back a fresh budget anyway.
// 2. Pace-based bad-time/caution (rank 2/1): only when pace is .active and
//    onPaceToExhaust — imminent (<=30min to full) is badTimeToStart, else caution.
// 3. Accumulation-based caution (rank 1): only checked if 1-2 didn't match —
//    catches a burst that already went idle (outside pace's ~25min memory).
// 4. Otherwise nil (no verdict for that window).
// warningThreshold does NOT by itself trigger caution — it only gates #3
// (util must be at least half of it) and sets the bar a window must stay
// under to ever count as "confidently safe" for .goodTime below.
// The two windows' results are compared and the higher rank wins. .goodTime
// (rank 0) is a separate, positive-only path reached when neither window
// produced a candidate above; see isSafe() below for why a nil pace can't
// qualify as safe.
enum Recommendation {
    case critical(windowLabel: String, percent: Int)
    case badTimeToStart(windowLabel: String, eta: String)
    case caution(windowLabel: String)
    case goodTime
}

let fiveHourDuration: TimeInterval = 5 * 3600
let sevenDayDuration: TimeInterval = 7 * 24 * 3600

/// Evaluates both windows and returns the single most relevant recommendation
/// plus its rank (0 = no warning, i.e. `.goodTime` or nil), or nil if neither
/// a warning nor a confident "good time" affirmation applies.
func recommendation(
    fiveUtil: Double?, fivePace: PaceResult?, fiveSecondsUntilReset: Double?,
    sevenUtil: Double?, sevenPace: PaceResult?, sevenSecondsUntilReset: Double?,
    warningThreshold: Double, criticalThreshold: Double
) -> (rank: Int, rec: Recommendation?) {
    let imminentThreshold: TimeInterval = 30 * 60

    func severity(util: Double?, pace: PaceResult?, secondsUntilReset: Double?, windowDuration: TimeInterval, label: String) -> (rank: Int, rec: Recommendation)? {
        guard let util = util else { return nil }
        // Suppress critical when reset is imminent: exceeding 100% this close to
        // a fresh window costs at most secondsUntilReset of blocked time, not a
        // real "wrap up soon" situation — the closer to reset, the less a raw
        // percentage matters. Reuses imminentThreshold (already the app's
        // notion of "urgent" elsewhere in this function) rather than adding a
        // second magic number. Falls through to the pace/accumulation checks
        // below instead of returning nil outright, though in practice those are
        // naturally quiet this close to reset too (pace already reports
        // .nearReset under 10min; the accumulation signal's elapsedFraction
        // approaches 1). A nil secondsUntilReset (unknown) is treated as "not
        // imminent" — suppression only applies when we positively know reset
        // is close, never as a default.
        let resetImminent = secondsUntilReset.map { $0 <= imminentThreshold } ?? false
        if util >= criticalThreshold, !resetImminent {
            return (3, .critical(windowLabel: label, percent: Int(util.rounded())))
        }
        if case .active(let p) = pace, p.onPaceToExhaust {
            if p.secondsToFull <= imminentThreshold {
                return (2, .badTimeToStart(windowLabel: label, eta: formatDuration(p.secondsToFull)))
            }
            return (1, .caution(windowLabel: label))
        }
        // Accumulation-based signal, independent of recent pace: catches a burst that
        // happened earlier in the window (outside PaceTracker's ~25-min sample buffer) and
        // then went idle — consumed-so-far still far outpacing elapsed-so-far even though
        // the recent rate now reads idle. Naturally becomes very hard to trigger near a
        // reset (elapsedFraction approaches 1), which is correct: little time left before
        // reset means little residual risk regardless of how much was already consumed.
        if let secondsUntilReset = secondsUntilReset, secondsUntilReset > 0 {
            let elapsedFraction = 1 - min(max(secondsUntilReset / windowDuration, 0), 1)
            let consumedFraction = util / 100
            if consumedFraction > elapsedFraction * 1.5, util >= warningThreshold * 0.5 {
                return (1, .caution(windowLabel: label))
            }
        }
        return nil
    }

    let candidates = [
        severity(util: fiveUtil, pace: fivePace, secondsUntilReset: fiveSecondsUntilReset, windowDuration: fiveHourDuration, label: "5h"),
        severity(util: sevenUtil, pace: sevenPace, secondsUntilReset: sevenSecondsUntilReset, windowDuration: sevenDayDuration, label: "7d"),
    ].compactMap { $0 }
    if let worst = candidates.max(by: { $0.rank < $1.rank }) {
        return (worst.rank, worst.rec)
    }

    // Neither window triggered a warning — only claim "good time" when both
    // windows are confidently low. Pace being nil (e.g. the pace indicator is
    // toggled off, so no rate was computed) must not be treated as "safe" —
    // that would assert a confidence about exhaustion risk we don't actually
    // have, unlike a genuinely known-idle/known-not-exhausting pace.
    func isSafe(util: Double?, pace: PaceResult?) -> Bool {
        guard let util = util, util < warningThreshold, let pace = pace else { return false }
        if case .active(let p) = pace, p.onPaceToExhaust { return false }
        return true
    }
    if isSafe(util: fiveUtil, pace: fivePace) && isSafe(util: sevenUtil, pace: sevenPace) {
        return (0, .goodTime)
    }
    return (0, nil)
}

// MARK: - Extra-usage (overage) pace

// Unlike five_hour/seven_day, extra_usage carries no API-provided cycle-reset date at all — so
// there's no real billing-cycle boundary to project against. AppSettings.extraUsageCycleStartedAt
// is a locally-inferred stand-in (set on first observation, reset whenever
// extraUsageCycleReset() detects a drop — see Formatting.swift), and this assumed length is a
// genuine approximation: real billing months run 28-31 days and the true cycle anniversary may
// not even be monthly-aligned. Deliberately NOT PaceTracker's short-window slope machinery — spend accumulates over weeks, not minutes, so a
// long-run average (consumed-so-far / elapsed-so-far, the same accumulation-ratio shape already
// validated for Recommendation.swift's 5h/7d caution signal) is the right fit, and is inherently
// far smoother than a short-window slope — no hysteresis/dwell needed the way PaceTracker's
// short-window rate does, since one poll barely moves a long-run average.
let extraUsageCycleDuration: TimeInterval = 30 * 24 * 3600

enum ExtraUsagePace {
    case noData                                        // cycle < 1 day old — too little signal to project
    case idle                                           // zero spend so far — nothing to extrapolate, not "on pace"
    case onTrack(projectedPercentAtCycleEnd: Double)    // extrapolated %, <= 100
    case onPaceToExceed(projectedDayOfCycle: Int)       // day-of-cycle (1-based) the cap would be hit
}

/// Projects monthly overage spend forward from a locally-tracked cycle start, using a simple
/// average-rate extrapolation (usedFraction / elapsedFraction) rather than a recent-slope blend —
/// appropriate for a slow, monotonic-within-cycle signal sampled once per ~150s poll.
func extraUsagePace(usedFraction: Double, cycleStartedAt: Date, now: Date = Date(), cycleDuration: TimeInterval = extraUsageCycleDuration) -> ExtraUsagePace {
    let elapsed = now.timeIntervalSince(cycleStartedAt)
    // Require at least a day of real data before projecting — early-cycle noise (e.g. one large
    // purchase on day 1) would otherwise extrapolate wildly, mirroring PaceTracker's own
    // few-samples/near-reset suppression for the same underlying reason.
    guard elapsed >= 86400 else { return .noData }
    let elapsedFraction = min(max(elapsed / cycleDuration, 0), 1)
    guard elapsedFraction > 0 else { return .noData }
    // Zero spend so far isn't a "0% on pace" trend to extrapolate — it's the absence of one.
    // Without this, usedFraction == 0 fell through to .onTrack(0), reading as an actual
    // pace verdict ("on pace for ~0%") rather than "nothing spent yet," the same distinction
    // PaceResult already draws between .idle and a genuine .active(0%-ish) trend.
    guard usedFraction > 0 else { return .idle }
    let projectedFraction = usedFraction / elapsedFraction
    if projectedFraction > 1 {
        // Day-of-cycle (1-based) at which cumulative spend would first reach 100%, assuming the
        // average rate-so-far (usedFraction / elapsedDays) holds constant: day = 1 / rate.
        // usedFraction > 0 is guaranteed here: projectedFraction > 1 with elapsedFraction > 0
        // (guarded above) means usedFraction > elapsedFraction > 0.
        let elapsedDays = elapsed / 86400
        let dayToExceed = elapsedDays / usedFraction
        return .onPaceToExceed(projectedDayOfCycle: Int(dayToExceed.rounded()))
    }
    return .onTrack(projectedPercentAtCycleEnd: projectedFraction * 100)
}