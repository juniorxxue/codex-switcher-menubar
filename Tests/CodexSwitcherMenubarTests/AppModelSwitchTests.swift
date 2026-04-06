import XCTest
@testable import CodexSwitcherMenubar

@MainActor
final class AppModelSwitchTests: XCTestCase {
    override func tearDown() {
        unsetenv("CODEX_SWITCHER_MENUBAR_STORAGE_DIR")
        unsetenv("CODEX_HOME")
        unsetenv("CODEX_SWITCHER_SKIP_STARTUP_REFRESH")
        super.tearDown()
    }

    func testActivateAccountUpdatesActiveOrderingAndAuthFile() async throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitcherMenubarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let storageDirectory = sandboxRoot.appendingPathComponent("storage", isDirectory: true)
        let codexHome = sandboxRoot.appendingPathComponent("codex-home", isDirectory: true)
        setenv("CODEX_SWITCHER_MENUBAR_STORAGE_DIR", storageDirectory.path, 1)
        setenv("CODEX_HOME", codexHome.path, 1)
        setenv("CODEX_SWITCHER_SKIP_STARTUP_REFRESH", "1", 1)

        let firstAccount = StoredAccount(
            id: UUID(uuidString: "FE3B5908-4986-4178-9D47-5D72CE723C65")!,
            name: "First",
            email: "first@example.com",
            planType: "plus",
            authMode: .chatGPT,
            apiKey: nil,
            chatGPT: ChatGPTCredential(
                idToken: "first.id.token",
                accessToken: "first.access.token",
                refreshToken: "first.refresh.token",
                accountID: "account-first"
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: nil
        )
        let secondAccount = StoredAccount(
            id: UUID(uuidString: "53D9930C-3F4F-4CB6-B757-483D74D7FA3E")!,
            name: "Second",
            email: "second@example.com",
            planType: "team",
            authMode: .chatGPT,
            apiKey: nil,
            chatGPT: ChatGPTCredential(
                idToken: "second.id.token",
                accessToken: "second.access.token",
                refreshToken: "second.refresh.token",
                accountID: "account-second"
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastUsedAt: nil
        )

        try LocalStore.save(
            AccountsStore(
                version: 1,
                activeAccountID: firstAccount.id,
                accounts: [firstAccount, secondAccount],
                maskedAccountIDs: []
            )
        )
        try AuthFileService.writeCurrentAuth(for: firstAccount)

        let model = AppModel()
        XCTAssertEqual(model.activeAccount?.id, firstAccount.id)
        XCTAssertEqual(model.accounts.first?.id, firstAccount.id)

        await model.activateAccount(secondAccount.id)

        XCTAssertEqual(model.activeAccount?.id, secondAccount.id)
        XCTAssertEqual(model.accounts.first?.id, secondAccount.id)

        let persistedStore = try LocalStore.load()
        XCTAssertEqual(persistedStore.activeAccountID, secondAccount.id)

        let authData = try Data(contentsOf: AppPaths.codexAuthFile)
        let authJSON = try JSONCoding.decoder().decode(AuthJSON.self, from: authData)
        XCTAssertEqual(authJSON.tokens?.accountID, "account-second")
        XCTAssertEqual(authJSON.tokens?.accessToken, "second.access.token")
    }
}
