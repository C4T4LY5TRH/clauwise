import AppKit
import Foundation
import Network

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let client = UsageClient()
    let localLog = LocalSessionLogReader()
    let paceTracker = PaceTracker()
    let recommendationTracker = RecommendationTracker()
    var timer: Timer?
    let pathMonitor = NWPathMonitor()
    var lastPathStatus: NWPath.Status?

    var isFetching = false
    // Mirrored into AppSettings/UserDefaults on every change (see
    // AppSettings.lastFetchStartedAt) so a relaunch remembers how recently
    // the *previous* process polled, instead of starting nil and potentially
    // re-hitting the network inside the server's real throttle window on a
    // quick quit-and-reopen. Seeded from storage in applicationDidFinishLaunching.
    var lastFetchStarted: Date? {
        didSet { AppSettings.shared.lastFetchStartedAt = lastFetchStarted }
    }
    private var statusLineLaunchHandled = false
    var lastGoodUsage: UsageResponse?
    var lastGoodSummary: TodayUsageSummary?
    var lastGoodAt: Date?
    var lastErrorMessage: String?
    var lastErrorDisplayMessage: String?
    var lastWarning: String?
    var lastFailureKind: FailureKind?
    // Same persistence rationale as lastFetchStarted above.
    var cooldownUntil: Date? {
        didSet { AppSettings.shared.cooldownUntilStored = cooldownUntil }
    }
    var appNapActivity: NSObjectProtocol?

    // The poll timer and menu-open refresh share one schedule (see
    // scheduleNextPoll() below), so this is the real floor on sustained
    // request rate, not just an overlap guard: a timer tick and a menu-open
    // don't count as two independent triggers. A shorter floor let bursts of
    // menu-opens (each far enough apart to pass the guard) stack on top of
    // the 150s timer and trigger 429s from the endpoint. 90s trades a little
    // freshness for real headroom under its rate budget.
    static let minRefreshInterval: TimeInterval = 90
    // minRefreshInterval also gates the very *first* refresh() call of a
    // fresh process. lastFetchStarted is deliberately persisted across
    // relaunches (protects the server budget, see its own comment above),
    // but lastGoodUsage/lastGoodSummary — what's actually on screen — are
    // NOT persisted, so a fresh process always starts with nothing to
    // render. A quick relaunch inside the 90s window therefore left the menu
    // stuck on the bare "…" loading placeholder for up to a full
    // pollInterval (150s), with no way to force it (a menu-open just calls
    // refresh(), gated by the same throttle). A blanket bypass of
    // minRefreshInterval whenever lastGoodUsage is nil would defeat the
    // purpose of persisting the throttle (a 429 was observed 4s after a
    // rapid relaunch), so a much shorter floor applies to exactly that
    // "nothing to show yet" case instead of removing the floor outright.
    static let minFirstFetchInterval: TimeInterval = 20
    // 90s was tried as the *poll* interval on its own and reverted: a short
    // observation window looked clean, but the multi-day log showed 146 real
    // httpStatus(429) failures, recurring as often as every ~12 minutes on
    // some days. 150s remains the only *unconditional, unattended* cadence
    // with a multi-day clean track record. This constant is still that same
    // safe baseline; it no longer solely governs request rate on its own,
    // since scheduleNextPoll() now also gets reset by menu-triggered
    // fetches (bounded below by minRefreshInterval above) rather than firing
    // as a second, independent source of requests.
    static let pollInterval: TimeInterval = 150
    static let rateLimitCooldown: TimeInterval = 150
    // Past this age, cached data shown after a failure is "last known good"
    // rather than "fresh" — the warning banner gains an age suffix.
    static let freshnessWindow: TimeInterval = pollInterval * 1.5
    // In-call retry for transient network errors only — kept inside one
    // refresh() Task so it never overlaps the poll timer or a manual tap.
    static let networkRetryDelaysNanos: [UInt64] = [2_000_000_000, 4_000_000_000]

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")
        // Restore the previous process's throttle state before the first
        // refresh() call below — see the didSet comments on lastFetchStarted/
        // cooldownUntil for why this matters.
        lastFetchStarted = AppSettings.shared.lastFetchStartedAt
        cooldownUntil = AppSettings.shared.cooldownUntilStored
        UsageNotifier.shared.requestAuthorization()
        // Menu-bar accessory apps (no visible window) are exactly the profile
        // macOS App Nap targets for throttling background Timer work — this
        // token opts the process out of that throttling for its lifetime.
        // MUST use .userInitiatedAllowingIdleSystemSleep here, not
        // .userInitiated: per Apple's NSActivityOptions definition,
        // .userInitiated's bitmask *includes* .idleSystemSleepDisabled, which
        // maps to a real "PreventUserIdleSystemSleep" IOKit/powerd assertion
        // (visible via `pmset -g assertions`; the same assertion caffeinate
        // uses to hold a Mac awake) — i.e. it keeps the machine from ever
        // sleeping for as long as this app runs. Only
        // .userInitiatedAllowingIdleSystemSleep gives the App Nap opt-out
        // without disabling idle system sleep.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "keep usage polling timely"
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = AppSettings.shared.iconStyle == .text ? "Claude: …" : "…"
        rebuildMenu(loading: true)
        // Deferred one run-loop turn so the menu bar item paints immediately
        // on launch rather than waiting on this synchronous file I/O first.
        DispatchQueue.main.async { [weak self] in
            if self?.lastGoodUsage == nil { self?.rebuildMenu(loading: true) }
        }
        // refresh() itself (re)arms the next poll via scheduleNextPoll()
        // once a fetch attempt completes, and every subsequent poll keeps
        // re-arming itself the same way — see scheduleNextPoll()'s comment
        // for why this replaced a fixed Timer(repeats: true). But this
        // first call can be skipped outright (e.g. a quick relaunch inside
        // the persisted minRefreshInterval throttle) with no fetch ever started to later arm anything.
        // Schedule a fallback here unconditionally as a safety net; a real
        // fetch (this one or the next trigger) invalidates and replaces it
        // via scheduleNextPoll() the moment it completes, so this only ever
        // matters when nothing else would have scheduled a timer at all.
        refresh()
        scheduleNextPoll()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let previous = self.lastPathStatus
            self.lastPathStatus = path.status
            if previous == .unsatisfied, path.status == .satisfied {
                log("network path restored — triggering immediate refresh")
                self.refresh()
            }
        }
        pathMonitor.start(queue: .main)
        // A resumed Mac would otherwise just wait for the next scheduled
        // Timer tick — which after a long sleep can itself be delayed,
        // leaving stale/transitional menu text (e.g. "resets in:
        // refreshing…") frozen on screen far longer than the single poll
        // cycle it was written to expect. refresh()'s own guards
        // (isFetching/cooldownUntil/minRefreshInterval) make this safe to
        // call opportunistically.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            log("system woke from sleep — triggering immediate refresh")
            self?.refresh()
        }
    }

    // Unifies the background poll timer and menu-open-triggered refreshes
    // onto one shared schedule, instead of two independent triggers that can
    // stack (see the minRefreshInterval comment above for why). Whatever *actually* fires a fetch — a timer tick
    // or a menu open — re-arms the next timer tick for pollInterval from
    // *this* fetch, so a menu-open effectively "absorbs" the pending timer
    // tick rather than adding a second request alongside it. Called once at
    // the end of every completed fetch attempt in refresh()'s Task — both
    // the success path and every exit of the catch block, including the
    // rate-limit-cooldown case, so a fetch that *enters* cooldown still
    // leaves a real timer pending (roughly coinciding with when the
    // cooldown itself clears, since both use ~pollInterval-scale durations)
    // rather than stranding the app with nothing scheduled. Deliberately
    // NOT called from refresh()'s skip-guards at the top (isFetching,
    // cooldown, throttle) — a skipped call means a real fetch already
    // handled (or will handle) re-arming, and re-arming again from a skip
    // would only pull the pending timer earlier than it should be.
    private func scheduleNextPoll(after interval: TimeInterval = AppDelegate.pollInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    // isFetching/cooldownUntil/lastFetchStarted are plain (non-actor-isolated)
    // properties — safe only because every caller (the poll Timer, @objc menu
    // actions, applicationDidFinishLaunching) runs on the main thread via
    // standard AppKit dispatch. Don't call refresh() from a background thread.
    func refresh() {
        if isFetching {
            log("refresh() skipped: already in flight")
            return
        }
        if let cooldown = cooldownUntil, Date() < cooldown {
            log("refresh() skipped: in rate-limit cooldown for \(cooldown.timeIntervalSinceNow)s more")
            return
        }
        // A process with nothing rendered yet (lastGoodUsage nil — always true
        // right after launch) uses the much shorter minFirstFetchInterval
        // instead of the steady-state minRefreshInterval: someone is
        // staring at a bare loading placeholder with no cached data to fall
        // back on, so getting them *something* takes priority over the full
        // 90s cadence floor. See minFirstFetchInterval's own comment above
        // for why this isn't just deleted outright.
        let effectiveThrottle = lastGoodUsage == nil ? Self.minFirstFetchInterval : Self.minRefreshInterval
        if let last = lastFetchStarted, Date().timeIntervalSince(last) < effectiveThrottle {
            log("refresh() skipped: throttled (last started \(Date().timeIntervalSince(last))s ago, threshold \(effectiveThrottle)s)")
            // Deliberately no re-arm here: the timer that's currently pending
            // (set by the last real fetch, whatever triggered it, to fire
            // pollInterval later) is always further out than this throttle
            // window, so it's still correctly scheduled — re-arming here
            // would only pull it *earlier*, silently tightening the
            // background cadence below pollInterval any time a menu-open
            // lands inside the throttle window. See scheduleNextPoll()'s
            // comment for why the cooldown guard above doesn't need this
            // either (the fetch that entered cooldown already re-armed
            // itself from its own catch block).
            return
        }
        isFetching = true
        lastFetchStarted = Date()
        log("refresh() called")
        Task { @MainActor in
            defer { self.isFetching = false }
            var attempt = 0
            while true {
                do {
                    let usage = try await client.fetch()
                    log("fetch succeeded: 5h=\(usage.five_hour?.utilization ?? -1) (resets_at=\(usage.five_hour?.resets_at ?? "nil")) 7d=\(usage.seven_day?.utilization ?? -1) (resets_at=\(usage.seven_day?.resets_at ?? "nil")) extra_usage(enabled=\(usage.extra_usage?.is_enabled?.description ?? "nil"), limit=\(usage.extra_usage?.scaledMonthlyLimit?.description ?? "nil"), used=\(usage.extra_usage?.scaledUsedCredits?.description ?? "nil"))")
                    self.cooldownUntil = nil
                    let summary = await Task.detached(priority: .utility) { [localLog] in
                        localLog.summarizeToday()
                    }.value
                    log("local summary: models=\(summary.totalsByModel.keys.sorted()) active=\(summary.activeModel ?? "none") activeTs=\(summary.activeModelTimestamp?.description ?? "none")")
                    var windowRolledOver = false
                    // Skip recording while there's no active session (nil resets_at at 0%,
                    // which persists for as long as no message is sent —
                    // not a single-poll transient). Recording through it would fill the ring
                    // buffer with an hour+ of flat 0% samples that, once a real session starts,
                    // drag fullRate's slope calculation down for the buffer's ~25-minute
                    // lifetime instead of reflecting the fresh burst. Skipping also means the
                    // next real sample correctly triggers record()'s own rolledOverByResetDate
                    // flush (comparing against the last *real* sample, not a stale zero one).
                    if let f = usage.five_hour?.utilization, !noActiveSession(utilization: f, resetsAt: usage.five_hour?.resets_at) {
                        if self.paceTracker.record(windowKey: WindowKey.fiveHour, utilization: f,
                            resetsAt: usage.five_hour?.resets_at.flatMap { parseISO($0) }) {
                            windowRolledOver = true
                        }
                    }
                    if let s = usage.seven_day?.utilization, !noActiveSession(utilization: s, resetsAt: usage.seven_day?.resets_at) {
                        if self.paceTracker.record(windowKey: WindowKey.sevenDay, utilization: s,
                            resetsAt: usage.seven_day?.resets_at.flatMap { parseISO($0) }) {
                            windowRolledOver = true
                        }
                    }
                    if windowRolledOver {
                        self.recommendationTracker.reset()
                    }
                    RecommendationTelemetry.record(usage: usage, paceTracker: self.paceTracker)
                    self.lastGoodUsage = usage
                    self.lastGoodSummary = summary
                    self.lastGoodAt = Date()
                    self.lastErrorMessage = nil
                    self.lastErrorDisplayMessage = nil
                    self.lastWarning = nil
                    self.lastFailureKind = nil
                    UsageNotifier.shared.clearAuthNotification()
                    // Extra-usage percent computed once, up front, and reused for both cycle-start
                    // bookkeeping and the notification call below. Cycle-start bookkeeping happens
                    // before render() so the pace line it draws (read live from AppSettings inside
                    // rebuildMenu) reflects this poll's state, not the previous one.
                    var extraUsagePercent: Double?
                    if let extra = usage.extra_usage, extra.is_enabled == true,
                       let limit = extra.scaledMonthlyLimit, limit > 0 {
                        let used = extra.scaledUsedCredits ?? 0
                        let percent = (used / limit) * 100
                        extraUsagePercent = percent
                        if extraUsageCycleReset(current: percent, previous: AppSettings.shared.lastExtraUsagePercent) {
                            AppSettings.shared.extraUsageCycleStartedAt = Date()
                        } else if AppSettings.shared.extraUsageCycleStartedAt == nil {
                            AppSettings.shared.extraUsageCycleStartedAt = Date() // first-ever observation
                        }
                    }
                    self.render(usage, summary: summary)
                    self.handleStatusLineOnLaunch()
                    UsageExport.write(usage, summary: summary)
                    UsageNotifier.shared.notifyIfNeeded(windowKey: WindowKey.fiveHour, label: "Session (5h)", percent: usage.five_hour?.utilization, resetsAt: usage.five_hour?.resets_at)
                    UsageNotifier.shared.notifyIfNeeded(windowKey: WindowKey.sevenDay, label: "Weekly (7d)", percent: usage.seven_day?.utilization, resetsAt: usage.seven_day?.resets_at)
                    if let extraUsagePercent = extraUsagePercent {
                        UsageNotifier.shared.notifyExtraUsageIfNeeded(percent: extraUsagePercent)
                    }
                    self.scheduleNextPoll()
                    return
                } catch {
                    let kind = classify(error)
                    let inCooldown = self.cooldownUntil.map { Date() < $0 } ?? false
                    if kind == .network, !inCooldown, attempt < Self.networkRetryDelaysNanos.count {
                        log("fetch failed (network, attempt \(attempt + 1)): \(error) — retrying")
                        try? await Task.sleep(nanoseconds: Self.networkRetryDelaysNanos[attempt])
                        attempt += 1
                        continue
                    }
                    log("fetch failed: \(error)")
                    self.lastErrorMessage = "\(error)"
                    self.lastFailureKind = kind
                    if kind == .auth {
                        UsageNotifier.shared.notifyAuthRequired()
                    }
                    if kind == .rateLimit {
                        self.cooldownUntil = Date().addingTimeInterval(Self.rateLimitCooldown)
                        log("entering rate-limit cooldown until \(self.cooldownUntil!)")
                    }
                    let message = kind == .auth ? authMessage(for: error) : shortErrorDescription(error)
                    let displayMsg = kind == .auth ? message : "\(error)"
                    var warning = message
                    if let at = self.lastGoodAt, Date().timeIntervalSince(at) >= Self.freshnessWindow {
                        warning += " (as of \(relativeAge(at)) ago)"
                    }
                    self.lastWarning = warning
                    self.lastErrorDisplayMessage = displayMsg
                    // Keep showing the last known-good data instead of wiping the UI on a
                    // transient failure (e.g. a 429 rate limit from overlapping requests) —
                    // only fall back to a bare error state if we've never had good data.
                    if let usage = self.lastGoodUsage {
                        self.render(usage, summary: self.lastGoodSummary ?? TodayUsageSummary(), warning: warning)
                    } else {
                        self.applyNoDataTitle()
                        self.rebuildMenu(error: displayMsg)
                    }
                    self.scheduleNextPoll()
                    return
                }
            }
        }
    }

    @MainActor
    func render(_ usage: UsageResponse, summary: TodayUsageSummary, warning: String? = nil) {
        let five = usage.five_hour?.utilization
        let seven = usage.seven_day?.utilization

        let title = NSMutableAttributedString()
        switch AppSettings.shared.iconStyle {
        case .text:
            title.append(NSAttributedString(string: "Claude: ", attributes: [.foregroundColor: NSColor.labelColor]))
            if let f = five {
                title.append(NSAttributedString(string: "5h \(Int(f))%", attributes: [.foregroundColor: severityColor(nil, fallbackPercent: f)]))
            }
            if five != nil && seven != nil {
                title.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: NSColor.labelColor]))
            }
            if let s = seven {
                title.append(NSAttributedString(string: "7d \(Int(s))%", attributes: [.foregroundColor: severityColor(nil, fallbackPercent: s)]))
            }
        case .compact:
            if let f = five {
                title.append(NSAttributedString(string: "5h \(Int(f))%", attributes: [.foregroundColor: severityColor(nil, fallbackPercent: f)]))
            }
            if five != nil && seven != nil {
                title.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: NSColor.labelColor]))
            }
            if let s = seven {
                title.append(NSAttributedString(string: "7d \(Int(s))%", attributes: [.foregroundColor: severityColor(nil, fallbackPercent: s)]))
            }
        case .minimal:
            // Show the 5-hour percentage (most real-time view); fall back to 7d if unavailable.
            let display = five ?? seven
            if let d = display {
                let prefix = (five != nil) ? "5h " : "7d "
                title.append(NSAttributedString(string: "\(prefix)\(Int(d))%", attributes: [.foregroundColor: severityColor(nil, fallbackPercent: d)]))
            }
        }
        let fivePace: PaceResult?
        let sevenPace: PaceResult?
        if AppSettings.shared.showPaceIndicator {
            fivePace = {
                guard let f = five, let str = usage.five_hour?.resets_at, let d = parseISO(str) else { return .noData }
                return paceTracker.pace(forKey: WindowKey.fiveHour, currentUtil: f, secondsUntilReset: d.timeIntervalSinceNow)
            }()
            sevenPace = {
                guard let s = seven, let str = usage.seven_day?.resets_at, let d = parseISO(str) else { return .noData }
                return paceTracker.pace(forKey: WindowKey.sevenDay, currentUtil: s, secondsUntilReset: d.timeIntervalSinceNow)
            }()
            let fiveExhausting = if case .active(let p) = fivePace { p.onPaceToExhaust } else { false }
            let sevenExhausting = if case .active(let p) = sevenPace { p.onPaceToExhaust } else { false }
            if fiveExhausting || sevenExhausting {
                title.append(NSAttributedString(string: " 🔥", attributes: [.foregroundColor: NSColor.systemOrange]))
            }
        } else {
            fivePace = nil
            sevenPace = nil
        }
        if warning != nil {
            title.append(NSAttributedString(string: " ⚠", attributes: [.foregroundColor: NSColor.systemOrange]))
        }
        statusItem.button?.attributedTitle = title
        rebuildMenu(usage: usage, summary: summary, warning: warning, fivePace: fivePace, sevenPace: sevenPace)
    }

    // Sets the title bar to the "no cached data" error state, with auth failures
    // distinguished visually (orange "login") from other errors (plain "err").
    @MainActor private func applyNoDataTitle() {
        let isAuth = lastFailureKind == .auth
        let text: String
        switch AppSettings.shared.iconStyle {
        case .text:    text = isAuth ? "Claude: login" : "Claude: err"
        case .compact, .minimal: text = isAuth ? "login" : "err"
        }
        let color: NSColor = isAuth ? .gruvboxOrange : .labelColor
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text, attributes: [.foregroundColor: color])
    }

    // MARK: - Menu item helpers

    private func addLine(_ text: String, into menu: NSMenu) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.gruvboxFg]
        )
        menu.addItem(item)
    }

    private func addCaveatLine(_ text: String, color: NSColor = .gruvboxGray, into menu: NSMenu) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        menu.addItem(item)
    }

    private func addPaceResult(_ result: PaceResult?, into menu: NSMenu) {
        switch result {
        case .active(let pace):
            let rateStr = String(format: "+%.1f%%/hr", pace.ratePerHour)
            if pace.onPaceToExhaust {
                addLine("  🔥 \(rateStr) — full in ~\(formatDuration(pace.secondsToFull))", into: menu)
            } else {
                addLine("  ↑ \(rateStr) — on pace for ~\(Int(pace.projectedAtReset.rounded()))% at reset", into: menu)
            }
            if let secs = pace.secondsToWarning {
                addCaveatLine("  ⚠ hits \(Int(AppSettings.shared.warningThreshold))% in ~\(formatDuration(secs))", color: .gruvboxOrange, into: menu)
            }
        case .idle:
            addCaveatLine("  ↑ pace: currently idle", into: menu)
        case .noData:
            addCaveatLine("  ↑ pace: collecting data…", into: menu)
        case .nearReset, nil:
            break
        }
    }

    // MARK: - Menu section builders

    private func buildErrorSection(into menu: NSMenu, error: String) {
        addLine("Error fetching usage", into: menu)
        addLine(error, into: menu)
        // An expired token is renewed by opening Claude Code, not by logging in again.
        if lastFailureKind == .auth, error != authMessage(for: KeychainError.expired) {
            let copyItem = NSMenuItem(title: "Copy: claude login", action: #selector(copyLoginCommand), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }
    }

    private func buildWarningBanner(into menu: NSMenu, warning: String?) {
        if let warning = warning {
            addCaveatLine("⚠ Last refresh failed (\(warning)) — showing cached data", color: .gruvboxOrange, into: menu)
            menu.addItem(NSMenuItem.separator())
        }
    }

    private func buildRecommendationSection(into menu: NSMenu, usage: UsageResponse, fivePace: PaceResult?, sevenPace: PaceResult?) {
        let fiveSecondsUntilReset = usage.five_hour?.resets_at.flatMap(parseISO)?.timeIntervalSinceNow
        let sevenSecondsUntilReset = usage.seven_day?.resets_at.flatMap(parseISO)?.timeIntervalSinceNow
        let computed = recommendation(
            fiveUtil: usage.five_hour?.utilization, fivePace: fivePace, fiveSecondsUntilReset: fiveSecondsUntilReset,
            sevenUtil: usage.seven_day?.utilization, sevenPace: sevenPace, sevenSecondsUntilReset: sevenSecondsUntilReset,
            warningThreshold: AppSettings.shared.warningThreshold,
            criticalThreshold: AppSettings.shared.criticalThreshold
        )
        let rec = recommendationTracker.apply(rank: computed.rank, rec: computed.rec)
        switch rec {
        case .critical(let label, let pct):
            addCaveatLine("⚠ Already at \(pct)% (\(label)) — wrap up soon", color: .gruvboxRed, into: menu)
            menu.addItem(NSMenuItem.separator())
        case .badTimeToStart(let label, let eta):
            addCaveatLine("🚫 Bad time to start big work — \(label) exhausts in ~\(eta)", color: .gruvboxRed, into: menu)
            menu.addItem(NSMenuItem.separator())
        case .caution(let label):
            addCaveatLine("⏳ On pace to exhaust \(label) before reset — consider lighter work", color: .gruvboxOrange, into: menu)
            menu.addItem(NSMenuItem.separator())
        case .goodTime:
            addCaveatLine("✅ Good time to start deep work — plenty of headroom", color: .gruvboxGreen, into: menu)
            menu.addItem(NSMenuItem.separator())
        case nil:
            break
        }
    }

    // The nil-resets_at fallback used below was written for a single ~150s poll-cycle
    // gap (see comment at the first use site). If the app has actually gone
    // without a successful fetch for much longer than that (e.g. the Mac slept
    // for hours), "refreshing…" is misleading — it reads as imminent when the
    // data is genuinely stale. Distinguish the two using the same lastGoodAt/
    // freshnessWindow staleness signal already used for the fetch-failure
    // warning banner (self.lastGoodAt read directly, same pattern as
    // self.cooldownUntil elsewhere in this function).
    private func computeStaleness(usage: UsageResponse) -> (staleGap: String?, fiveResetDate: Date?, sevenResetDate: Date?) {
        let staleGap: String? = {
            guard let at = self.lastGoodAt, Date().timeIntervalSince(at) >= Self.freshnessWindow else { return nil }
            return "last update \(relativeAge(at)) ago"
        }()
        let fiveResetDate = usage.five_hour?.resets_at.flatMap(parseISO)
        let sevenResetDate = usage.seven_day?.resets_at.flatMap(parseISO)
        return (staleGap, fiveResetDate, sevenResetDate)
    }

    private func buildFiveHourSection(into menu: NSMenu, usage: UsageResponse, fivePace: PaceResult?, staleGap: String?, fiveResetDate: Date?) {
        guard let five = usage.five_hour else { return }
        addLine("Session (5h): \(Int(five.utilization ?? 0))%", into: menu)
        if let resetDate = fiveResetDate {
            addLine("  \(formatResetLine(to: resetDate))", into: menu)
        } else if let staleGap {
            // Staleness trumps the no-active-session read: cached data this old
            // may not reflect reality (a session could've started elsewhere since
            // the last successful poll), so don't assert "no active session" on
            // data that might simply be outdated.
            addLine("  resets in: unknown (\(staleGap))", into: menu)
        } else if noActiveSession(utilization: five.utilization, resetsAt: five.resets_at) {
            addLine("  no active session — starts on next message", into: menu)
        } else {
            addLine("  resets in: refreshing…", into: menu)
        }
        if AppSettings.shared.showPaceIndicator {
            if fiveResetDate == nil, let staleGap {
                addCaveatLine("  ↑ pace: unavailable (\(staleGap))", into: menu)
            } else if fiveResetDate == nil, noActiveSession(utilization: five.utilization, resetsAt: five.resets_at) {
                // No line — pace is meaningless with no session running.
            } else {
                addPaceResult(fivePace, into: menu)
            }
        }
    }

    private func buildSevenDaySection(into menu: NSMenu, usage: UsageResponse, sevenPace: PaceResult?, staleGap: String?, sevenResetDate: Date?, fiveHasNoActiveSession: Bool) {
        guard let seven = usage.seven_day else { return }
        addLine("Weekly (7d): \(Int(seven.utilization ?? 0))%", into: menu)
        if let resetDate = sevenResetDate {
            addLine("  \(formatResetLine(to: resetDate))", into: menu)
        } else if let staleGap {
            addLine("  resets in: unknown (\(staleGap))", into: menu)
        } else if noActiveSession(utilization: seven.utilization, resetsAt: seven.resets_at) {
            addLine("  no active session — starts on next message", into: menu)
        } else {
            addLine("  resets in: refreshing…", into: menu)
        }
        if AppSettings.shared.showPaceIndicator {
            if sevenResetDate == nil, let staleGap {
                addCaveatLine("  ↑ pace: unavailable (\(staleGap))", into: menu)
            } else if sevenResetDate == nil, noActiveSession(utilization: seven.utilization, resetsAt: seven.resets_at) {
                // No line — pace is meaningless with no session running.
            } else if fiveHasNoActiveSession, isNoDataOrIdle(sevenPace) {
                // The 5h window has no active session at all right now. A weekly
                // pace of .noData/.idle in that state doesn't mean "collecting
                // data" or "genuinely idle usage trend" — it's just an artifact of
                // there being no session running to sample from, mirroring the 5h
                // section's own "no active session" read one line up. Showing
                // "pace: collecting data…"/"currently idle" here read as
                // contradictory next to a real, non-zero 7d percentage and a real
                // reset date — so suppress it the same way the 5h pace line is
                // suppressed in its own no-session state, rather than asserting a
                // pace verdict the data doesn't support. A genuine .active/.nearReset
                // result still renders normally — this only touches the two
                // "nothing to report yet" cases.
            } else {
                addPaceResult(sevenPace, into: menu)
            }
        }
    }

    /// True for `.noData`/`.idle` — the two `PaceResult` cases that mean "no
    /// pace verdict formed yet," as opposed to `.active`/`.nearReset` which
    /// carry a real one.
    private func isNoDataOrIdle(_ result: PaceResult?) -> Bool {
        switch result {
        case .noData, .idle: return true
        case .active, .nearReset, .none: return false
        }
    }

    private func buildExtraUsageSection(into menu: NSMenu, usage: UsageResponse) {
        addLine("Usage credits (overage)", into: menu)
        if let extra = usage.extra_usage, extra.is_enabled == true {
            let used = extra.scaledUsedCredits ?? 0
            let limit = extra.scaledMonthlyLimit ?? 0
            let currency = extra.currency ?? ""
            // This is spend-against-your-configured-cap, NOT a credit balance you own —
            // A line like "Add-on credits: 0% (0.00/100.00)" can read as "you have 100 of
            // credit", which would be misleading: the real balance is unrelated to this
            // monthly limit. `monthly_limit` is the self-set spend cap
            // (Claude.ai Settings > Usage > "Monthly spend limit"), not a credit amount.
            // The actual balance isn't in this API response at all 
            addLine("  Monthly spend: \(formatMoney(used, currency)) / \(formatMoney(limit, currency)) limit", into: menu)
            // Same "Pace Indicator" toggle that gates the 5h/7d pace lines — one concept,
            // one on/off switch, rather than a second toggle for this smaller feature.
            // extraUsageCycleStartedAt is nil until the first poll observes extra_usage
            // enabled (see refresh()); until then there's nothing to project from yet.
            if AppSettings.shared.showPaceIndicator, limit > 0,
               let cycleStart = AppSettings.shared.extraUsageCycleStartedAt {
                switch extraUsagePace(usedFraction: used / limit, cycleStartedAt: cycleStart) {
                case .noData:
                    addCaveatLine("  ↑ pace: collecting data…", into: menu)
                case .idle:
                    addCaveatLine("  ↑ pace: no overage spend yet this cycle", into: menu)
                case .onTrack(let projectedPercent):
                    addLine("  ↑ on pace for ~\(Int(projectedPercent.rounded()))% of \(formatMoney(limit, currency)) cap by cycle end", into: menu)
                case .onPaceToExceed(let day):
                    addLine("  🔥 on pace to hit \(formatMoney(limit, currency)) cap around day \(day) (of ~30)", into: menu)
                }
            }
        } else {
            addLine("  not enabled", into: menu)
        }
    }

    private func buildTodaysTokensSection(into menu: NSMenu, summary: TodayUsageSummary?) {
        guard let summary = summary else { return }
        menu.addItem(NSMenuItem.separator())
        addCaveatLine("Today's tokens (CLI only)", into: menu)
        if summary.totalsByModel.isEmpty {
            addLine("  no CLI usage today", into: menu)
        } else {
            let sorted = summary.totalsByModel.sorted { $0.value.totalTokens > $1.value.totalTokens }
            for (model, totals) in sorted {
                addLine("  \(model): \(formatCount(totals.inputTokens)) in / \(formatCount(totals.outputTokens)) out", into: menu)
                let hitRateSuffix = totals.cacheHitRate.map { " (\(Int($0))% hit rate)" } ?? ""
                addCaveatLine("    cache: \(formatCount(totals.cacheReadTokens)) read / \(formatCount(totals.cacheCreationTokens)) created\(hitRateSuffix)", into: menu)
            }
        }

        if let activeModel = summary.activeModel, let ts = summary.activeModelTimestamp,
           Date().timeIntervalSince(ts) < 15 * 60 {
            menu.addItem(NSMenuItem.separator())
            addCaveatLine("Active model (CLI only)", into: menu)
            addLine("  \(activeModel)", into: menu)
        }
    }

    private func buildDisplayStyleSubmenu(into menu: NSMenu) {
        let styleMenu = NSMenu()
        for style in IconStyle.allCases {
            let label: String
            switch style {
            case .text:    label = "Text  (Claude: 5h 42% · 7d 14%)"
            case .compact: label = "Compact  (5h 42% · 7d 14%)"
            case .minimal: label = "Minimal  (5h 42%)"
            }
            let item = NSMenuItem(title: label, action: #selector(setIconStyle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = IconStyle.allCases.firstIndex(of: style)!
            item.state = AppSettings.shared.iconStyle == style ? .on : .off
            styleMenu.addItem(item)
        }
        let styleParent = NSMenuItem(title: "Display Style", action: nil, keyEquivalent: "")
        styleParent.submenu = styleMenu
        menu.addItem(styleParent)
    }

    private func buildNotificationsSubmenu(into menu: NSMenu) {
        let notifMenu = NSMenu()
        for preset in NotificationPreset.allCases {
            let item = NSMenuItem(title: preset.label, action: #selector(setNotificationPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = NotificationPreset.allCases.firstIndex(of: preset)!
            item.state = AppSettings.shared.notificationPreset == preset ? .on : .off
            notifMenu.addItem(item)
        }
        let notifParent = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        notifParent.submenu = notifMenu
        menu.addItem(notifParent)
    }

    private func buildToggles(into menu: NSMenu) {
        let paceItem = NSMenuItem(title: "Pace Indicator", action: #selector(togglePaceIndicator), keyEquivalent: "")
        paceItem.target = self
        paceItem.state = AppSettings.shared.showPaceIndicator ? .on : .off
        menu.addItem(paceItem)

        if StatusLineInstaller.shared.claudeCLIInstalled {
            let statusLineItem: NSMenuItem
            let statusLineStatus = StatusLineInstaller.shared.currentStatus()
            switch statusLineStatus {
            case .conflict:
                statusLineItem = NSMenuItem(title: "Claude Code Status Line (custom command set)", action: nil, keyEquivalent: "")
                statusLineItem.isEnabled = false
            case .unreadable:
                statusLineItem = NSMenuItem(title: "Claude Code Status Line (settings.json unreadable)", action: nil, keyEquivalent: "")
                statusLineItem.isEnabled = false
            case .installedByUs, .outdated, .legacyMatch, .notInstalled:
                statusLineItem = NSMenuItem(title: "Claude Code Status Line", action: #selector(toggleStatusLine), keyEquivalent: "")
                statusLineItem.target = self
                statusLineItem.state = (statusLineStatus == .notInstalled) ? .off : .on
            }
            menu.addItem(statusLineItem)
        }

        menu.addItem(NSMenuItem.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)
    }

    private func buildFooter(into menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshTapped), keyEquivalent: "r")
        refreshItem.target = self
        if let cooldown = self.cooldownUntil, Date() < cooldown {
            let remaining = Int(cooldown.timeIntervalSinceNow.rounded(.up))
            refreshItem.title = "Refresh now (in \(remaining)s)"
            refreshItem.isEnabled = false
        }
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitTapped), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @MainActor
    func rebuildMenu(usage: UsageResponse? = nil, summary: TodayUsageSummary? = nil, loading: Bool = false, error: String? = nil, warning: String? = nil, fivePace: PaceResult? = nil, sevenPace: PaceResult? = nil) {
        let menu = NSMenu()
        menu.delegate = self

        if loading {
            addLine("Loading usage…", into: menu)
        } else if let error = error {
            buildErrorSection(into: menu, error: error)
        } else if let usage = usage {
            buildWarningBanner(into: menu, warning: warning)
            buildRecommendationSection(into: menu, usage: usage, fivePace: fivePace, sevenPace: sevenPace)
            let (staleGap, fiveResetDate, sevenResetDate) = computeStaleness(usage: usage)
            buildFiveHourSection(into: menu, usage: usage, fivePace: fivePace, staleGap: staleGap, fiveResetDate: fiveResetDate)
            menu.addItem(NSMenuItem.separator())
            // usage.five_hour != nil guards against a rare decode failure on that one field
            // (decodeLenient isolates it per-field, see UsageAPI.swift) being misread as a
            // *confirmed* no-active-session state — noActiveSession(nil, nil) would otherwise
            // return true on missing data via its `utilization ?? 0` fallback, wrongly
            // suppressing the 7d pace line's own genuine .noData/.idle text below.
            let fiveHasNoActiveSession = usage.five_hour != nil && fiveResetDate == nil && staleGap == nil
                && noActiveSession(utilization: usage.five_hour?.utilization, resetsAt: usage.five_hour?.resets_at)
            buildSevenDaySection(into: menu, usage: usage, sevenPace: sevenPace, staleGap: staleGap, sevenResetDate: sevenResetDate, fiveHasNoActiveSession: fiveHasNoActiveSession)

            menu.addItem(NSMenuItem.separator())
            buildExtraUsageSection(into: menu, usage: usage)

            buildTodaysTokensSection(into: menu, summary: summary)
        }

        menu.addItem(NSMenuItem.separator())

        buildDisplayStyleSubmenu(into: menu)
        buildNotificationsSubmenu(into: menu)
        buildToggles(into: menu)
        buildFooter(into: menu)

        statusItem.menu = menu
    }

    // Fires the moment the dropdown is actually opened — the real
    // point of staleness perception, not an arbitrary background timer tick.
    // Two independent refreshes, each gated appropriately for its own data
    // source: refreshLocalSummary() always re-reads local disk (cheap, no
    // rate limit); refresh()'s own isFetching/cooldownUntil/
    // minRefreshInterval (90s, see its own comment) guards make it free to
    // call unconditionally too — if the cached value is already recent
    // (<90s old), this is a same-thread no-op showing what's already on
    // screen; only a genuinely stale view triggers a real network call, and
    // that call also re-arms the background poll timer via
    // scheduleNextPoll() rather than leaving both to fire independently.
    func menuWillOpen(_ menu: NSMenu) {
        refreshLocalSummary()
        refresh()
    }

    // Last time refreshLocalSummary() actually ran the disk walk (main-thread
    // only, same guarantee as isFetching/cooldownUntil elsewhere).
    private var lastLocalSummaryRefresh: Date?
    // Deliberately much shorter than refresh()'s 90s minRefreshInterval —
    // this is cheap local I/O with no external rate limit to protect, so the
    // only goal is debouncing a rapid-fire open/close of the menu (each open
    // walks every ~/.claude/projects/**/*.jsonl file), not staleness.
    static let minLocalSummaryInterval: TimeInterval = 5

    // Refreshes only the local Claude Code session-log summary ("Today's
    // tokens" / "Active model") — pure local file I/O with no external rate
    // limit, so intentionally NOT gated by refresh()'s network throttle
    // guards (isFetching/cooldownUntil/minRefreshInterval). Those guards
    // exist solely to protect the /api/oauth/usage rate budget; there's no
    // equivalent reason to hold this back, so it's called unconditionally on
    // every menu open and stays as fresh as the last message you sent even
    // while the account-wide 5h/7d % is mid-cooldown. A harmless duplicate
    // read can happen if refresh() also proceeds in the same call (it does
    // its own summarizeToday() after a successful fetch) — cheap local I/O,
    // not worth the extra plumbing to dedupe. Still debounced by
    // minLocalSummaryInterval so rapid repeated menu opens don't re-walk the
    // whole log tree on every single one.
    func refreshLocalSummary() {
        if let last = lastLocalSummaryRefresh, Date().timeIntervalSince(last) < Self.minLocalSummaryInterval {
            return
        }
        lastLocalSummaryRefresh = Date()
        Task.detached(priority: .utility) { [localLog] in
            let summary = localLog.summarizeToday()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastGoodSummary = summary
                log("local summary refreshed (menu open): models=\(summary.totalsByModel.keys.sorted()) active=\(summary.activeModel ?? "none")")
                if let usage = self.lastGoodUsage {
                    self.render(usage, summary: summary, warning: self.lastWarning)
                }
            }
        }
    }

    @objc func refreshTapped() { refresh() }
    @objc func quitTapped() { NSApp.terminate(nil) }
    @objc func copyLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude login", forType: .string)
    }
    @MainActor @objc func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        if let usage = lastGoodUsage {
            render(usage, summary: lastGoodSummary ?? TodayUsageSummary(), warning: lastWarning)
        } else {
            applyNoDataUI()
        }
    }
    @MainActor @objc func setIconStyle(_ sender: NSMenuItem) {
        let styles = IconStyle.allCases
        guard sender.tag < styles.count else { return }
        AppSettings.shared.iconStyle = styles[sender.tag]
        if let usage = lastGoodUsage {
            render(usage, summary: lastGoodSummary ?? TodayUsageSummary(), warning: lastWarning)
        } else {
            if let errMsg = lastErrorDisplayMessage {
                applyNoDataTitle()
                rebuildMenu(error: errMsg)
            } else {
                statusItem.button?.title = AppSettings.shared.iconStyle == .text ? "Claude: …" : "…"
                rebuildMenu(loading: true)
            }
        }
    }
    @MainActor @objc func setNotificationPreset(_ sender: NSMenuItem) {
        let presets = NotificationPreset.allCases
        guard sender.tag < presets.count else { return }
        AppSettings.shared.notificationPreset = presets[sender.tag]
        if let usage = lastGoodUsage {
            render(usage, summary: lastGoodSummary ?? TodayUsageSummary(), warning: lastWarning)
        } else {
            applyNoDataUI()
        }
    }
    @MainActor @objc func togglePaceIndicator() {
        AppSettings.shared.showPaceIndicator.toggle()
        if let usage = lastGoodUsage {
            render(usage, summary: lastGoodSummary ?? TodayUsageSummary(), warning: lastWarning)
        } else {
            applyNoDataUI()
        }
    }
    // Runs after each successful render, but acts at most once per launch
    // (the prompt itself at most once ever, since either answer is stored).
    @MainActor private func handleStatusLineOnLaunch() {
        guard !statusLineLaunchHandled else { return }
        statusLineLaunchHandled = true
        let installer = StatusLineInstaller.shared
        switch installer.launchAction(choice: AppSettings.shared.statusLineChoice) {
        case .nothing:
            break
        case .adoptExisting:
            AppSettings.shared.statusLineChoice = .enabled
        case .repairOwnEntry:
            if installer.install() { log("StatusLineInstaller: repaired own entry") }
        case .promptUser:
            // One run-loop turn later so the menu bar has finished painting
            // the usage that just arrived before a modal appears.
            DispatchQueue.main.async { [weak self] in self?.promptForStatusLine() }
        }
    }

    @MainActor private func promptForStatusLine() {
        let alert = NSAlert()
        alert.messageText = "Show usage in the Claude Code status line?"
        alert.informativeText = "Clauwise can add one entry to ~/.claude/settings.json so your 5-hour and 7-day usage appear at the bottom of Claude Code. Your existing settings are kept and a one-time backup is made. You can change this any time from the menu."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "No Thanks")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if StatusLineInstaller.shared.install() {
                AppSettings.shared.statusLineChoice = .enabled
            } else {
                log("StatusLineInstaller: install from first-run prompt failed")
            }
        } else {
            AppSettings.shared.statusLineChoice = .declined
        }
        if let usage = lastGoodUsage {
            render(usage, summary: lastGoodSummary ?? TodayUsageSummary(), warning: lastWarning)
        }
    }

    @MainActor @objc func toggleStatusLine() {
        switch StatusLineInstaller.shared.currentStatus() {
        case .installedByUs, .outdated, .legacyMatch:
            if StatusLineInstaller.shared.uninstall() {
                AppSettings.shared.statusLineChoice = .declined
            }
        case .notInstalled:
            if StatusLineInstaller.shared.install() {
                AppSettings.shared.statusLineChoice = .enabled
            }
        case .conflict, .unreadable:
            break // menu item is disabled in this state, unreachable
        }
        if let usage = lastGoodUsage {
            render(usage, summary: lastGoodSummary ?? TodayUsageSummary(), warning: lastWarning)
        } else {
            applyNoDataUI()
        }
    }

    // Shared no-good-data branch for menu actions: rebuilds menu without touching the button title.
    @MainActor private func applyNoDataUI() {
        if let errMsg = lastErrorDisplayMessage {
            rebuildMenu(error: errMsg)
        } else {
            rebuildMenu(loading: true)
        }
    }
}

private let sharedCountFormatter: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; return f
}()

func formatCount(_ n: Int) -> String {
    sharedCountFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

func formatMoney(_ amount: Double, _ currency: String) -> String {
    String(format: "%.2f %@", amount, currency)
}
