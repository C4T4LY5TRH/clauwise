import Testing
import Foundation
@testable import Clauwise

private func credsJSON(expiresAtMs: Double) -> Data {
    Data("""
    {"claudeAiOauth":{"accessToken":"tok","refreshToken":"ignored","expiresAt":\(expiresAtMs),"scopes":["a"]}}
    """.utf8)
}

@Test func credentialsDecodeIgnoresRefreshToken() throws {
    let creds = try CredentialStore.decode(credsJSON(expiresAtMs: 1_000))
    #expect(creds.accessToken == "tok")
    #expect(creds.expiresAt == 1_000)
}

@Test func malformedCredentialsAreReported() {
    #expect(throws: KeychainError.self) { try CredentialStore.decode(Data("{}".utf8)) }
}

@Test func expiryIsJudgedAgainstMilliseconds() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    #expect(OAuthCreds(accessToken: "t", expiresAt: 1_999_000).isExpired(at: now))
    #expect(OAuthCreds(accessToken: "t", expiresAt: 2_000_000).isExpired(at: now))
    #expect(!OAuthCreds(accessToken: "t", expiresAt: 2_001_000).isExpired(at: now))
}

@Test func credentialFailuresClassifyAsAuth() {
    #expect(classify(KeychainError.expired) == .auth)
    #expect(classify(KeychainError.notFound) == .auth)
    #expect(classify(KeychainError.malformed) == .auth)
}

@Test func expiredTokenHasSpecificMessage() {
    #expect(authMessage(for: KeychainError.expired)
        == "Your Claude Code login has expired — open Claude Code once to refresh it")
    #expect(shortErrorDescription(KeychainError.expired) == authMessage(for: KeychainError.expired))
    #expect(authMessage(for: KeychainError.notFound) == "sign in again (run claude login)")
}

@Test func httpErrorsClassifyWithoutBodies() {
    #expect(classify(UsageAPIError.httpStatus(429)) == .rateLimit)
    #expect(classify(UsageAPIError.httpStatus(401)) == .auth)
    #expect(classify(UsageAPIError.httpStatus(500)) == .other)
    #expect(shortErrorDescription(UsageAPIError.httpStatus(500)) == "HTTP 500")
}
