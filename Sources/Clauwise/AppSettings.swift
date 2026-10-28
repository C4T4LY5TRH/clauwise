import Foundation

// MARK: - Icon style for the menu bar status item title

enum IconStyle: String, CaseIterable {
    case text     // "Claude: 5h 42% · 7d 14%"
    case compact  // "5h 42% · 7d 14%"
    case minimal  // 5-hour percentage only (falls back to 7d if unavailable), e.g. "42%"
}

// MARK: - Notification threshold presets

enum NotificationPreset: String, CaseIterable {
    case normal     // 70% warning / 90% critical
    case aggressive // 50% warning / 80% critical
    case relaxed    // 85% warning / 95% critical

    var warningThreshold: Double {
        switch self { case .normal: return 70; case .aggressive: return 50; case .relaxed: return 85 }
    }
    var criticalThreshold: Double {
        switch self { case .normal: return 90; case .aggressive: return 80; case .relaxed: return 95 }
    }
    var label: String {
        switch self {
        case .normal:     return "Normal (70%/90%)"
        case .aggressive: return "Aggressive (50%/80%)"
        case .relaxed:    return "Relaxed (85%/95%)"
        }
    }
}

// MARK: - Claude Code status line consent

enum StatusLineChoice: String {
    case enabled
    case declined
}

// MARK: - Persisted preferences

final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let iconStyle = "iconStyle"
        static let notificationPreset = "notificationPreset"
        static let notifiedTierPrefix = "notifiedTier."
        static let lastResetsAtPrefix = "lastResetsAt."
        static let showPaceIndicator = "showPaceIndicator"
        static let statusLineChoice = "statusLineChoice"
        static let recordUsageHistory = "recordUsageHistory"
        static let lastFetchStartedAt = "lastFetchStartedAt"
        static let cooldownUntilStored = "cooldownUntilStored"
        static let paceSamplesPrefix      = "paceSamples."
        static let paceWindowResetAtPrefix = "paceWindowResetAt."
        static let authFailureNotifiedAt  = "authFailureNotifiedAt"
        static let lastExtraUsagePercent  = "lastExtraUsagePercent"
        static let extraUsageCycleStartedAt = "extraUsageCycleStartedAt"
        static let recommendationLogLastPrunedAt = "recommendationLogLastPrunedAt"
    }

    var iconStyle: IconStyle {
        get { IconStyle(rawValue: defaults.string(forKey: Keys.iconStyle) ?? "") ?? .text }
        set { defaults.set(newValue.rawValue, forKey: Keys.iconStyle) }
    }

    var notificationPreset: NotificationPreset {
        get { NotificationPreset(rawValue: defaults.string(forKey: Keys.notificationPreset) ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Keys.notificationPreset) }
    }

    var warningThreshold: Double { notificationPreset.warningThreshold }
    var criticalThreshold: Double { notificationPreset.criticalThreshold }

    // Off unless explicitly enabled; when off, nothing is written to the
    // usage-history file. Enable with:
    //   defaults write io.github.c4t4ly5trh.clauwise recordUsageHistory -bool true
    var recordUsageHistory: Bool {
        get { defaults.object(forKey: Keys.recordUsageHistory) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.recordUsageHistory) }
    }

    var showPaceIndicator: Bool {
        get { defaults.object(forKey: Keys.showPaceIndicator) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showPaceIndicator) }
    }

    // Shared Date<->TimeInterval-via-UserDefaults round-trip, used by every
    // Date-backed persisted property below (lastResetsAt, authFailureNotifiedAt,
    // lastFetchStartedAt, cooldownUntilStored, storedPaceWindowResetAt) instead
    // of each reimplementing the same get/set/remove-on-nil pattern.
    private func date(forKey key: String) -> Date? {
        let t = defaults.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    private func setDate(_ date: Date?, forKey key: String) {
        if let date = date {
            defaults.set(date.timeIntervalSince1970, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // The answer to the optional Claude Code status line prompt. nil means
    // never answered: the first-run prompt is still pending, and nothing has
    // been written to Claude Code's settings.
    var statusLineChoice: StatusLineChoice? {
        get { defaults.string(forKey: Keys.statusLineChoice).flatMap(StatusLineChoice.init(rawValue:)) }
        set {
            if let newValue = newValue {
                defaults.set(newValue.rawValue, forKey: Keys.statusLineChoice)
            } else {
                defaults.removeObject(forKey: Keys.statusLineChoice)
            }
        }
    }

    // MARK: - Notification de-dup persistence

    // Replaces UsageNotifier's in-memory notifiedTier/lastResetsAt dicts so that
    // de-dup state survives app relaunches — prevents re-firing if usage is already
    // above a threshold when the app starts mid-period.

    func notifiedTier(forKey key: String) -> Severity? {
        guard let raw = defaults.string(forKey: Keys.notifiedTierPrefix + key) else { return nil }
        return Severity(rawValue: raw)
    }
    func setNotifiedTier(_ tier: Severity?, forKey key: String) {
        if let tier = tier {
            defaults.set(tier.rawValue, forKey: Keys.notifiedTierPrefix + key)
        } else {
            defaults.removeObject(forKey: Keys.notifiedTierPrefix + key)
        }
    }
    func lastResetsAt(forKey key: String) -> Date? { date(forKey: Keys.lastResetsAtPrefix + key) }
    func setLastResetsAt(_ newDate: Date?, forKey key: String) { setDate(newDate, forKey: Keys.lastResetsAtPrefix + key) }

    // MARK: - Auth failure notification de-dup persistence

    // Tracks when we last fired the "sign in required" notification so we
    // don't spam on every poll while auth stays broken. Cleared on successful
    // fetch; re-fires after 24h if still broken.

    var authFailureNotifiedAt: Date? {
        get { date(forKey: Keys.authFailureNotifiedAt) }
        set { setDate(newValue, forKey: Keys.authFailureNotifiedAt) }
    }

    // MARK: - Fetch throttle persistence

    // Mirrors AppDelegate's in-memory lastFetchStarted/cooldownUntil so a
    // relaunch remembers how recently the *previous* process polled, instead
    // of starting both nil and potentially re-hitting the network well
    // inside the server's real throttle window on a quick quit-and-reopen.

    var lastFetchStartedAt: Date? {
        get { date(forKey: Keys.lastFetchStartedAt) }
        set { setDate(newValue, forKey: Keys.lastFetchStartedAt) }
    }

    var cooldownUntilStored: Date? {
        get { date(forKey: Keys.cooldownUntilStored) }
        set { setDate(newValue, forKey: Keys.cooldownUntilStored) }
    }

    // MARK: - Extra-usage (overage) notification de-dup persistence

    // extra_usage has no API-provided cycle-reset date (unlike five_hour/seven_day's
    // resets_at), so UsageNotifier can't re-arm on a period boundary the way it does
    // for those two windows. Instead it re-arms when this stored percent drops versus
    // the new poll — spend within a billing cycle is monotonic, so a decrease reliably
    // means a new cycle started (mirrors PaceTracker's own sharp-drop reset heuristic).

    var lastExtraUsagePercent: Double? {
        get { defaults.object(forKey: Keys.lastExtraUsagePercent) as? Double }
        set {
            if let newValue = newValue {
                defaults.set(newValue, forKey: Keys.lastExtraUsagePercent)
            } else {
                defaults.removeObject(forKey: Keys.lastExtraUsagePercent)
            }
        }
    }

    // Local stand-in for the cycle-reset date the API doesn't provide for extra_usage — set on
    // first-ever observation and whenever extraUsageCycleReset() detects a new cycle. Feeds
    // Recommendation.swift's extraUsagePace(), which projects against elapsed-time-since-this
    // rather than a real billing-cycle boundary (see that function's own caveat comment).
    var extraUsageCycleStartedAt: Date? {
        get { date(forKey: Keys.extraUsageCycleStartedAt) }
        set { setDate(newValue, forKey: Keys.extraUsageCycleStartedAt) }
    }

    // MARK: - Pace sample persistence

    // Stores the *whole* recent sample buffer per window (up to PaceTracker's own
    // maxSamples, currently 10) so PaceTracker can seed a real, multi-point trend on
    // relaunch instead of a single point — a relaunch is common (routine quit/reopen,
    // app update, crash recovery) and a single-point seed would discard up to ~25 minutes of
    // accumulated trend, forcing pace() back through .noData/.idle for several more
    // poll cycles even during genuinely active, ongoing usage.
    //
    // Stored as JSON-encoded Data (one Data blob per window) rather than parallel
    // primitive arrays — simplest correct encoding for an array of (Date, Double)
    // pairs via UserDefaults, and PaceSample is a tiny value type so round-tripping
    // through JSONEncoder/JSONDecoder per read/write is cheap at this scale (≤10
    // samples, once per ~90-150s poll).

    func storedPaceSamples(forKey key: String) -> [PaceSample] {
        guard let data = defaults.data(forKey: Keys.paceSamplesPrefix + key),
              let decoded = try? JSONDecoder().decode([PaceSample].self, from: data) else { return [] }
        // Discard samples older than 24h individually (not the whole array) — rate
        // from a stale session is meaningless, but a handful of old entries mixed
        // into an otherwise-fresh array shouldn't disqualify the fresh ones too.
        return decoded.filter { Date().timeIntervalSince($0.timestamp) < 86400 }
    }
    func setStoredPaceSamples(_ samples: [PaceSample], forKey key: String) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        defaults.set(data, forKey: Keys.paceSamplesPrefix + key)
    }

    func storedPaceWindowResetAt(forKey key: String) -> Date? { date(forKey: Keys.paceWindowResetAtPrefix + key) }
    func setStoredPaceWindowResetAt(_ newDate: Date, forKey key: String) { setDate(newDate, forKey: Keys.paceWindowResetAtPrefix + key) }

    // MARK: - Recommendation accuracy telemetry pruning

    // Gates RecommendationTelemetry's full-file prune rewrite to at most
    // once/24h instead of on every append — see RecommendationTelemetry.swift.
    var recommendationLogLastPrunedAt: Date? {
        get { date(forKey: Keys.recommendationLogLastPrunedAt) }
        set { setDate(newValue, forKey: Keys.recommendationLogLastPrunedAt) }
    }
}
