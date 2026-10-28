import Foundation

// MARK: - Credentials
//
// Read-only view of the OAuth token Claude Code keeps in the login Keychain.
// This app never refreshes the token and never writes to the Keychain: when
// the stored token has expired, the app asks you to open Claude Code, which
// renews it.

struct OAuthCreds: Decodable {
    var accessToken: String
    var expiresAt: Double // milliseconds since the epoch

    func isExpired(at now: Date = Date()) -> Bool {
        expiresAt <= now.timeIntervalSince1970 * 1000
    }
}

struct CredsWrapper: Decodable {
    var claudeAiOauth: OAuthCreds
}

enum KeychainError: Error { case notFound, malformed, expired }

final class CredentialStore {
    static let service = "Claude Code-credentials"

    static func decode(_ data: Data) throws -> OAuthCreds {
        do {
            return try JSONDecoder().decode(CredsWrapper.self, from: data).claudeAiOauth
        } catch {
            throw KeychainError.malformed
        }
    }

    func read() throws -> OAuthCreds {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", Self.service, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0, !data.isEmpty else { throw KeychainError.notFound }
        return try Self.decode(data)
    }

    func validAccessToken() throws -> String {
        let creds = try read()
        guard !creds.isExpired() else { throw KeychainError.expired }
        return creds.accessToken
    }
}
