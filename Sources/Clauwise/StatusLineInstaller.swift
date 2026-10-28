import Foundation

// MARK: - Claude Code status line (opt-in)
//
// Wires `Clauwise statusline` into ~/.claude/settings.json's `statusLine`
// key so 5h/7d usage shows up in the Claude Code terminal. Only runs after
// the person using the app says yes (first-run prompt or the menu toggle). Reads/writes
// settings.json via JSONSerialization (not a rigid Codable model) so any
// unrelated keys already there are preserved untouched. Never overwrites a
// genuine third-party statusLine command — it only installs into a missing
// key, upgrades our own marked entry, or leaves a real conflict alone.
//
// `claudeDir` is injectable (not a hardcoded global) so tests can run
// against a scratch directory instead of the real ~/.claude/settings.json.

struct StatusLineInstaller {
    let claudeDir: URL
    var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }
    var backupURL: URL { claudeDir.appendingPathComponent("settings.json.clauwise-backup") }

    static let shared = StatusLineInstaller(
        claudeDir: URL(fileURLWithPath: NSString(string: "~/.claude").expandingTildeInPath)
    )

    var claudeCLIInstalled: Bool {
        FileManager.default.fileExists(atPath: claudeDir.path)
    }

    var ownCommand: String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Escape any embedded single quote (POSIX shell idiom: close the
        // quote, insert an escaped quote, reopen) so an install path like
        // "Chris's Apps/Clauwise.app" still produces valid shell syntax.
        let escaped = exe.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)' statusline"
    }

    // Re-runs the statusline command on a fixed timer (in addition to Claude
    // Code's own event-driven triggers — new message, /compact, etc.), per
    // https://code.claude.com/docs/en/statusline.md. Without this, a session
    // left idle across a sleep/wake or network gap shows stale data until the
    // next event fires (e.g. the first message of a session) — the exported
    // usage.json can be fresh seconds after wake, but nothing prompts Claude
    // Code to re-read it until this timer or a real event does. 60s (rather
    // than Clauwise's own 150s poll cadence) trades a little responsiveness
    // for far fewer redundant subprocess spawns re-reading unchanged data.
    static let ownRefreshInterval = 60

    // Written into our own statusLine entry so ownership can be recognized
    // independent of the exact `command` string — e.g. if Clauwise.app is
    // later moved (changing Bundle.main.executablePath), a marked entry is
    // still recognized as ours (falls to .outdated, self-heals to the new
    // path) rather than misread as a real third-party conflict. Only takes
    // effect from the point an install actually stamps it — an install from
    // before this field existed has no way to be retroactively distinguished
    // from a real customization by path alone, so it's recognized via the
    // literal command-string fallback below instead, one time, to bootstrap
    // the marker in.
    private static let markerKey = "_managedBy"
    private static let markerValue = "Clauwise"

    // The hand-wired bash+jq script used before the built-in subcommand
    // existed, plus this feature's own pre-marker command string — both
    // recognized via exact match so upgrading either doesn't read as a
    // conflict with a real customization. This match is inherently
    // ambiguous, though: someone who followed the old manual setup and then
    // hand-customized their own script (a file this class never touches)
    // still matches on the command string alone. See
    // `.legacyMatch` below for how that ambiguity is handled.
    private static let legacyCommand = "bash ~/.claude/statusline-command.sh"

    enum Status: Equatable {
        case notInstalled
        case installedByUs
        case outdated // marker present (unambiguously ours), but path/refreshInterval drifted — safe to silently auto-upgrade
        case legacyMatch // no marker: command matches a known legacy/pre-marker string, but real customization can't be ruled out — never silently auto-upgraded, only via explicit action from the person using the app
        case conflict(String)
        case unreadable // settings.json exists but isn't valid JSON — refuse to touch it rather than risk clobbering real content
    }

    func currentStatus() -> Status {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .notInstalled }
        guard let dict = readSettings() else { return .unreadable }
        return status(fromLoaded: dict)
    }

    // Derives Status from an already-loaded settings dict, so callers that
    // need both the status and the dict itself (install/uninstall) can read
    // settings.json exactly once instead of once via currentStatus() and
    // again for their own read-modify-write.
    private func status(fromLoaded dict: [String: Any]) -> Status {
        guard let statusLine = dict["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return .notInstalled
        }
        if (statusLine[Self.markerKey] as? String) == Self.markerValue {
            let pathCorrect = command == ownCommand
            let intervalCorrect = (statusLine["refreshInterval"] as? Int) == Self.ownRefreshInterval
            return (pathCorrect && intervalCorrect) ? .installedByUs : .outdated
        }
        // No marker yet: recognize a pre-marker install of this exact feature
        // (by its then-current path) or the original hand-wired script — but
        // only as .legacyMatch, not .outdated, since neither can be
        // corroborated beyond the bare command string.
        if command == ownCommand || command == Self.legacyCommand { return .legacyMatch }
        return .conflict(command)
    }

    @discardableResult
    func install() -> Bool {
        // Single read: a missing file means .notInstalled (proceed with an
        // empty dict); an existing-but-unparseable file means .unreadable
        // (refuse); otherwise derive status from the same dict this function
        // goes on to modify, rather than re-reading via currentStatus().
        var dict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard let loaded = readSettings() else { return false } // .unreadable
            switch status(fromLoaded: loaded) {
            case .conflict:
                return false
            default:
                break
            }
            dict = loaded
        }
        backupIfNeeded()
        var statusLine = dict["statusLine"] as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = ownCommand
        statusLine["refreshInterval"] = Self.ownRefreshInterval
        statusLine[Self.markerKey] = Self.markerValue
        dict["statusLine"] = statusLine
        return writeSettings(dict)
    }

    @discardableResult
    func uninstall() -> Bool {
        // Single read, same rationale as install(): derive status from the
        // one dict this function already needs, instead of a separate
        // currentStatus() call re-reading the file from scratch.
        guard var dict = readSettings() else { return false }
        switch status(fromLoaded: dict) {
        case .installedByUs, .outdated, .legacyMatch:
            break
        default:
            return false
        }
        if var statusLine = dict["statusLine"] as? [String: Any] {
            // Remove only the keys install() itself owns, mirroring its own
            // merge-not-replace guarantee — a sub-key added by hand or
            // by another tool while our status line was active (e.g. a
            // hand-added `padding`) survives uninstall instead of being
            // silently discarded along with everything else.
            statusLine.removeValue(forKey: "type")
            statusLine.removeValue(forKey: "command")
            statusLine.removeValue(forKey: "refreshInterval")
            statusLine.removeValue(forKey: Self.markerKey)
            if statusLine.isEmpty {
                dict.removeValue(forKey: "statusLine")
            } else {
                dict["statusLine"] = statusLine
            }
        }
        return writeSettings(dict)
    }

    enum LaunchAction: Equatable {
        case promptUser      // never asked and nothing is installed: ask once
        case adoptExisting   // our own marked entry is already there: record consent, ask nothing
        case repairOwnEntry  // opted in earlier but the entry drifted (e.g. the app moved)
        case nothing
    }

    // Pure decision for what to do at launch. Nothing here installs
    // anything: the only write that can follow is repairing an entry that was
    // already opted into, and installing happens only after an explicit "yes"
    // (first-run prompt or menu toggle). An unmarked match (.legacyMatch)
    // cannot be told apart from a hand-made customization by its command
    // string, and a genuine third-party command or unreadable file must stay
    // untouched, so those never prompt either.
    func launchAction(choice: StatusLineChoice?) -> LaunchAction {
        guard claudeCLIInstalled, choice != .declined else { return .nothing }
        switch (currentStatus(), choice) {
        case (.notInstalled, nil):
            return .promptUser
        case (.installedByUs, nil), (.outdated, nil):
            return .adoptExisting
        case (.outdated, .enabled?):
            return .repairOwnEntry
        default:
            return .nothing
        }
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func backupIfNeeded() {
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
    }

    private func writeSettings(_ dict: [String: Any]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            let tmpURL = claudeDir.appendingPathComponent("settings.json.tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: tmpURL)
            return true
        } catch {
            log("StatusLineInstaller: write failed: \(error)")
            return false
        }
    }
}
