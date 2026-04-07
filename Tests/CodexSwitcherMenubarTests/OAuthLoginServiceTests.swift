import XCTest
@testable import CodexSwitcherMenubar

final class OAuthLoginServiceTests: XCTestCase {
    func testStartLoginCreatesCallbackServer() async throws {
        let session = try await OAuthLoginService.startLogin(accountName: "Test Account")
        defer { session.cancel() }

        XCTAssertGreaterThan(session.callbackPort, 0)

        let components = try XCTUnwrap(URLComponents(url: session.authURL, resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)
        let redirectURI = queryItems.first(where: { $0.name == "redirect_uri" })?.value
        XCTAssertEqual(
            redirectURI,
            "http://localhost:\(session.callbackPort)/auth/callback"
        )
    }

    func testRequestedScopesMatchOfficialCodexFlow() {
        XCTAssertEqual(
            OAuthLoginService.requestedScopes,
            "openid profile email offline_access"
        )
    }

    func testParseListeningProcessSkipsCurrentPID() {
        let raw = """
        p123
        cCodexSwitcherMenubar
        p456
        ccodex-switcher
        """

        XCTAssertEqual(
            OAuthLoginService.parseListeningProcess(raw, excludingPID: 123),
            ListeningProcess(pid: 456, command: "codex-switcher")
        )
    }

    func testUserFacingOAuthErrorHighlightsMissingCodexEntitlement() {
        XCTAssertEqual(
            OAuthLoginService.userFacingOAuthErrorMessage(
                error: "access_denied",
                description: "missing_codex_entitlement"
            ),
            "Codex is not enabled for your workspace. Contact your workspace administrator to request access."
        )
    }

    func testUserFacingOAuthErrorFallsBackToDescription() {
        XCTAssertEqual(
            OAuthLoginService.userFacingOAuthErrorMessage(
                error: "server_error",
                description: "Failed to reach the local callback server."
            ),
            "Sign-in failed: Failed to reach the local callback server."
        )
    }
}
