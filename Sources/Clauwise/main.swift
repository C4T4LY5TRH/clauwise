import AppKit
import Foundation

func log(_ msg: String) {
    // Computed locally rather than as a main.swift top-level `let`: globals in
    // a script-style main.swift only initialize as part of that file's
    // top-level execution, which never runs when this module is imported as
    // a library (e.g. `@testable import` from the test target) — referencing
    // a top-level global from there crashed with a nil URL.
    let logURL = URL(fileURLWithPath: NSString(string: "~/Library/Logs/Clauwise.log").expandingTildeInPath)
    let line = "\(Date()) \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "statusline" {
    StatusLine.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
