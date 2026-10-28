import Testing
import Foundation
@testable import Clauwise

private func scratchInstaller(settings: String? = nil, createDir: Bool = true) throws -> StatusLineInstaller {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clauwise-test-\(UUID().uuidString)")
    if createDir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    if let settings = settings {
        try settings.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }
    return StatusLineInstaller(claudeDir: dir)
}

private func loadSettings(_ i: StatusLineInstaller) throws -> [String: Any] {
    let data = try Data(contentsOf: i.settingsURL)
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

// MARK: - launchAction: nothing installs without consent

@Test func freshInstallPromptsOnce() throws {
    let i = try scratchInstaller()
    #expect(i.launchAction(choice: nil) == .promptUser)
}

@Test func declinedNeverPromptsOrInstalls() throws {
    let i = try scratchInstaller()
    #expect(i.launchAction(choice: .declined) == .nothing)
}

@Test func noClaudeFolderMeansNoPrompt() throws {
    let i = try scratchInstaller(createDir: false)
    #expect(i.launchAction(choice: nil) == .nothing)
}

@Test func existingOwnEntryIsAdoptedWithoutPrompt() throws {
    let i = try scratchInstaller(settings: "{}")
    #expect(i.install())
    #expect(i.launchAction(choice: nil) == .adoptExisting)
    #expect(i.launchAction(choice: .enabled) == .nothing)
}

@Test func driftedOwnEntryIsRepairedOnlyAfterOptIn() throws {
    let i = try scratchInstaller(settings: """
    {"statusLine":{"type":"command","command":"/elsewhere/Clauwise statusline","_managedBy":"Clauwise"}}
    """)
    #expect(i.launchAction(choice: .enabled) == .repairOwnEntry)
    #expect(i.launchAction(choice: nil) == .adoptExisting)
}

@Test func foreignCommandIsNeverPromptedOrTouched() throws {
    let original = #"{"statusLine":{"type":"command","command":"my-own-script"}}"#
    let i = try scratchInstaller(settings: original)
    #expect(i.launchAction(choice: nil) == .nothing)
    #expect(!i.install())
    #expect(try String(contentsOf: i.settingsURL, encoding: .utf8) == original)
}

@Test func unreadableSettingsAreLeftAlone() throws {
    let i = try scratchInstaller(settings: "{not json")
    #expect(i.launchAction(choice: nil) == .nothing)
    #expect(!i.install())
    #expect(try String(contentsOf: i.settingsURL, encoding: .utf8) == "{not json")
}

// MARK: - install / uninstall invariants

@Test func installMergesBacksUpAndMarks() throws {
    let i = try scratchInstaller(settings: #"{"theme":"dark"}"#)
    #expect(i.install())
    let dict = try loadSettings(i)
    #expect(dict["theme"] as? String == "dark")
    let line = try #require(dict["statusLine"] as? [String: Any])
    #expect(line["_managedBy"] as? String == "Clauwise")
    #expect(line["refreshInterval"] as? Int == StatusLineInstaller.ownRefreshInterval)
    #expect(FileManager.default.fileExists(atPath: i.backupURL.path))
    #expect(i.currentStatus() == .installedByUs)
}

@Test func uninstallKeepsUnrelatedKeys() throws {
    let i = try scratchInstaller(settings: #"{"theme":"dark","statusLine":{"padding":2}}"#)
    #expect(i.install())
    #expect(i.uninstall())
    let dict = try loadSettings(i)
    #expect(dict["theme"] as? String == "dark")
    let line = try #require(dict["statusLine"] as? [String: Any])
    #expect(line["padding"] as? Int == 2)
    #expect(line["command"] == nil)
}

// MARK: - consent state

@Test func statusLineChoiceRoundTrips() {
    let settings = AppSettings.shared
    let saved = settings.statusLineChoice
    defer { settings.statusLineChoice = saved }
    settings.statusLineChoice = nil
    #expect(settings.statusLineChoice == nil)
    settings.statusLineChoice = .declined
    #expect(settings.statusLineChoice == .declined)
    settings.statusLineChoice = .enabled
    #expect(settings.statusLineChoice == .enabled)
}

@Test func usageHistoryDefaultsOff() {
    let key = "recordUsageHistory"
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
        if let saved = saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    UserDefaults.standard.removeObject(forKey: key)
    #expect(AppSettings.shared.recordUsageHistory == false)
}
