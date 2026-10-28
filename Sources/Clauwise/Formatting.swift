import AppKit
import Foundation

// MARK: - Date parsing

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoFormatterNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseISO(_ s: String) -> Date? {
    isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
}

// A nil resets_at paired with 0% utilization means no session has started since the
// last reset — the 5h window's clock starts on first use, not on a fixed schedule —
// rather than the transient single-poll boundary glitch a nil resets_at can also mean
// when utilization is nonzero. Confirmed via log: nil resets_at at 0% held across 100+
// consecutive successful polls (>1hr, through a sleep/wake cycle) with no self-heal.
func noActiveSession(utilization: Double?, resetsAt: String?) -> Bool {
    resetsAt == nil && (utilization ?? 0) <= 0
}

// extra_usage (monthly overage spend) has no API-provided cycle-reset date at all, unlike
// five_hour/seven_day's resets_at — so a new billing cycle can only be inferred locally, by
// noticing the tracked percent drop (spend within one cycle is monotonic, only ever increasing,
// so a decrease reliably means a new cycle started). Shared by both Notifications.swift's
// notification re-arm and AppDelegate's cycle-start bookkeeping for extra-usage pace projection,
// so the two can't silently diverge on what counts as "a new cycle." The 1-point buffer absorbs
// rounding noise between polls rather than flagging a spurious reset.
func extraUsageCycleReset(current: Double, previous: Double?) -> Bool {
    guard let previous = previous else { return false }
    return current < previous - 1
}

// MARK: - Display formatting

let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.timeZone = .current
    return f
}()

let weekdayDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM, HH:mm"
    f.timeZone = .current
    return f
}()

/// "resets in 2d 12h (Wed 24 Jun, 22:59)" for multi-day resets,
/// "resets in 45m (at 15:19)" for same-day resets.
func formatResetLine(to date: Date, now: Date = Date()) -> String {
    let secs = max(0, Int(date.timeIntervalSince(now)))
    let days = secs / 86400
    let hours = (secs % 86400) / 3600
    let minutes = (secs % 3600) / 60

    let countdown: String
    if days > 0 {
        countdown = "\(days)d \(hours)h"
    } else if hours > 0 {
        countdown = "\(hours)h \(minutes)m"
    } else {
        countdown = "\(minutes)m"
    }

    let sameDay = Calendar.current.isDate(date, inSameDayAs: now)
    if sameDay {
        return "resets in \(countdown) (at \(clockFormatter.string(from: date)))"
    } else {
        return "resets in \(countdown) (\(weekdayDateFormatter.string(from: date)))"
    }
}

// MARK: - Gruvbox dark palette

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            red:   CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8)  & 0xff) / 255,
            blue:  CGFloat( rgb        & 0xff) / 255,
            alpha: 1
        )
    }
    static let gruvboxFg     = NSColor(rgb: 0xebdbb2)  // cream — main info lines
    static let gruvboxGray   = NSColor(rgb: 0xa89984)  // fg4 — caveat/secondary
    static let gruvboxOrange = NSColor(rgb: 0xfe8019)  // bright orange — ⚠ warnings
    static let gruvboxGreen  = NSColor(rgb: 0xb8bb26)  // bright green — normal severity
    static let gruvboxYellow = NSColor(rgb: 0xfabd2f)  // bright yellow — warning severity
    static let gruvboxRed    = NSColor(rgb: 0xfb4934)  // bright red — critical severity
}

// MARK: - Severity coloring

func severityColor(_ severity: Severity?, fallbackPercent: Double?) -> NSColor {
    switch severity {
    case .critical: return .gruvboxRed
    case .warning:  return .gruvboxYellow
    case .normal:   return .gruvboxGreen
    case nil:
        guard let pct = fallbackPercent else { return .labelColor }
        if pct >= AppSettings.shared.criticalThreshold { return .gruvboxRed }
        if pct >= AppSettings.shared.warningThreshold  { return .gruvboxYellow }
        return .gruvboxGreen
    }
}

/// Short, user-facing description for the menu bar warning banner.
func shortErrorDescription(_ error: Error) -> String {
    if let apiError = error as? UsageAPIError {
        switch apiError {
        case .httpStatus(429):
            return "rate limited"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .decode:
            return "bad response"
        }
    }
    if error is KeychainError {
        return authMessage(for: error)
    }
    return "network error"
}

/// Banner text for an auth failure. An expired token is the common case and
/// has a specific remedy: Claude Code renews the token, this app never does.
func authMessage(for error: Error) -> String {
    if case KeychainError.expired = error {
        return "Your Claude Code login has expired — open Claude Code once to refresh it"
    }
    return "sign in again (run claude login)"
}

// MARK: - Failure classification (drives retry/backoff in refresh())

enum FailureKind { case rateLimit, network, auth, other }

func classify(_ error: Error) -> FailureKind {
    if let apiError = error as? UsageAPIError {
        switch apiError {
        case .httpStatus(429):
            return .rateLimit
        case .httpStatus(401), .httpStatus(403):
            return .auth
        case .httpStatus, .decode:
            return .other
        }
    }
    if let keychainError = error as? KeychainError {
        switch keychainError {
        case .notFound, .malformed, .expired:
            return .auth
        }
    }
    if error is URLError {
        return .network
    }
    return .other
}

private func formatSeconds(_ s: Int) -> String {
    let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "\(sec)s"
}

/// "2h 15m", "45m", "30s" — for pace projection display.
func formatDuration(_ seconds: Double) -> String {
    formatSeconds(max(0, Int(seconds)))
}

/// "45s", "12m", "2h 3m" — elapsed time since `date`, for staleness banners.
func relativeAge(_ date: Date, now: Date = Date()) -> String {
    formatSeconds(max(0, Int(now.timeIntervalSince(date))))
}
