import Foundation
import UserNotifications

// MARK: - Native notifications when a usage window crosses a severity threshold
//
// Fires once per escalation (normal -> warning -> critical), not on every
// poll while sitting above a threshold. De-dup state is keyed per window
// and cleared once that window's previously-stored resets_at is actually
// in the past (a genuine new period started), so the same tier can notify
// again next period.
//
// Thresholds are read from AppSettings.shared (default: 70%/90%) so they
// track whichever NotificationPreset is selected. De-dup state is persisted in
// UserDefaults (via AppSettings) so it survives app relaunches — prevents
// re-firing when usage is already above a threshold at launch time.

private func severityTier(forPercent percent: Double) -> Severity {
    let settings = AppSettings.shared
    if percent >= settings.criticalThreshold { return .critical }
    if percent >= settings.warningThreshold  { return .warning }
    return .normal
}

private func tierRank(_ severity: Severity) -> Int {
    switch severity {
    case .normal: return 0
    case .warning: return 1
    case .critical: return 2
    }
}

@MainActor
final class UsageNotifier {
    static let shared = UsageNotifier()

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                log("UsageNotifier: authorization error: \(error)")
            } else {
                log("UsageNotifier: authorization granted=\(granted)")
            }
        }
    }

    func notifyIfNeeded(windowKey: String, label: String, percent: Double?, resetsAt: String?) {
        guard let percent = percent else { return }
        let settings = AppSettings.shared

        // Re-arm if the stored reset date has passed — runs even when API omits resets_at,
        // preventing permanent silence if resets_at is ever null.
        if let stored = settings.lastResetsAt(forKey: windowKey), stored <= Date() {
            settings.setNotifiedTier(nil, forKey: windowKey)
        }
        if let resetsAt = resetsAt, let resetsDate = parseISO(resetsAt) {
            settings.setLastResetsAt(resetsDate, forKey: windowKey)
        }

        // Don't clear notifiedTier on a mid-period dip — only the period-reset
        // check above (stored <= Date()) re-arms it. Clearing here would allow
        // a second notification if usage recovers above threshold in the same period.
        fireIfEscalated(
            windowKey: windowKey,
            percent: percent,
            title: { $0 == .critical ? "Claude usage critical" : "Claude usage high" },
            body: { _ in "\(label): \(Int(percent))% used" },
            errorContext: "failed to deliver notification"
        )
    }

    // Extra-usage (overage) spend crossing a threshold — same tier/de-dup shape as
    // notifyIfNeeded above, but re-arms on a percent *decrease* rather than a stored
    // resets_at boundary, since extra_usage carries no cycle-reset date at all (see
    // AppSettings.lastExtraUsagePercent). Percent is the caller's own used/limit
    // ratio (from ExtraUsage.scaledUsedCredits/scaledMonthlyLimit), not the API's
    // extra_usage.utilization field, since the latter isn't currently used/verified
    // anywhere else in the app.
    func notifyExtraUsageIfNeeded(percent: Double) {
        let settings = AppSettings.shared
        let windowKey = WindowKey.extraUsage

        if extraUsageCycleReset(current: percent, previous: settings.lastExtraUsagePercent) {
            settings.setNotifiedTier(nil, forKey: windowKey)
        }
        settings.lastExtraUsagePercent = percent

        fireIfEscalated(
            windowKey: windowKey,
            percent: percent,
            title: { $0 == .critical ? "Claude usage credits critical" : "Claude usage credits high" },
            body: { _ in "Usage credits (overage): \(Int(percent))% of monthly spend limit used" },
            errorContext: "failed to deliver extra-usage notification"
        )
    }

    // Shared tail of both notifyIfNeeded/notifyExtraUsageIfNeeded above: tier
    // check, escalation-only de-dup guard, and UNNotificationRequest
    // construction/delivery. Re-arm logic differs per caller (resets_at
    // boundary vs. percent decrease) and stays at each call site above —
    // only the identical part both duplicated is centralized here, so a
    // future change to the de-dup/delivery mechanics only needs one edit.
    private func fireIfEscalated(
        windowKey: String,
        percent: Double,
        title: (Severity) -> String,
        body: (Severity) -> String,
        errorContext: String
    ) {
        let settings = AppSettings.shared
        let tier = severityTier(forPercent: percent)
        guard tier != .normal else { return }

        let previousTier = settings.notifiedTier(forKey: windowKey)
        guard previousTier == nil || tierRank(tier) > tierRank(previousTier!) else { return }
        settings.setNotifiedTier(tier, forKey: windowKey)

        let content = UNMutableNotificationContent()
        content.title = title(tier)
        content.body = body(tier)
        content.sound = .default

        let request = UNNotificationRequest(identifier: "\(windowKey)-\(tier.rawValue)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log("UsageNotifier: \(errorContext): \(error)")
            }
        }
    }

    // Fires once per auth-failure onset (and once per 24h if still broken).
    // Uses a fixed identifier so repeated calls replace rather than stack the banner.
    // Cleared by clearAuthNotification() on the next successful fetch.
    func notifyAuthRequired() {
        let settings = AppSettings.shared
        if let firedAt = settings.authFailureNotifiedAt,
           Date().timeIntervalSince(firedAt) < 86400 { return }

        let content = UNMutableNotificationContent()
        content.title = "Claude: Sign In Required"
        content.body = "Usage data unavailable — open Claude Code once to refresh your login."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "auth-required", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { log("UsageNotifier: auth notification error: \(error)") }
        }
        settings.authFailureNotifiedAt = Date()
        log("UsageNotifier: fired auth-required notification")
    }

    func clearAuthNotification() {
        AppSettings.shared.authFailureNotifiedAt = nil
    }
}
