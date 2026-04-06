import XCTest
import CryptoSwift
import zlib
@testable import CodexSwitcherMenubar

final class CodexSwitcherExportServiceTests: XCTestCase {
    func testFullExportCanBeImported() throws {
        let fixtureURL = try makeSyntheticFullExport()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let store = try CodexSwitcherExportService.importFullExport(from: fixtureURL)

        XCTAssertFalse(store.accounts.isEmpty)
        XCTAssertEqual(store.accounts.count, 2)

        if let activeAccountID = store.activeAccountID {
            XCTAssertTrue(store.accounts.contains(where: { $0.id == activeAccountID }))
        }
    }

    private func makeSyntheticFullExport() throws -> URL {
        let accountA = StoredAccount.makeAPIKey(name: "API", apiKey: "sk-test")
        let accountB = StoredAccount.makeChatGPT(
            name: "ChatGPT",
            email: "demo@example.com",
            planType: "plus",
            tokens: ChatGPTCredential(
                idToken: "demo.id.token",
                accessToken: "demo.access.token",
                refreshToken: "demo.refresh.token",
                accountID: "demo-account"
            )
        )

        let store = AccountsStore(
            version: 1,
            activeAccountID: accountB.id,
            accounts: [accountA, accountB],
            maskedAccountIDs: []
        )

        let json = try JSONCoding.encoder().encode(LegacyAccountsStore(from: store))
        let compressed = try compressZlib(json)
        let encrypted = try encryptCSWF(compressed)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("cswf")
        try encrypted.write(to: url)
        return url
    }

    private func compressZlib(_ data: Data) throws -> Data {
        var destination = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))))
        var destinationLength = uLongf(destination.count)

        let status = data.withUnsafeBytes { rawBuffer in
            let sourcePointer = rawBuffer.bindMemory(to: Bytef.self).baseAddress
            return compress2(
                &destination,
                &destinationLength,
                sourcePointer,
                uLong(data.count),
                Z_BEST_COMPRESSION
            )
        }

        guard status == Z_OK else {
            throw XCTSkip("Failed to build synthetic zlib payload.")
        }

        return Data(destination.prefix(Int(destinationLength)))
    }

    private func encryptCSWF(_ compressed: Data) throws -> Data {
        let passphrase = "gT7kQ9mV2xN4pL8sR1dH6zW3cB5yF0uJ_aE7nK2tP9vM4rX1"
        let salt = Array("0123456789abcdef".utf8)
        let nonce = Array("0123456789abcdefghijklmn".utf8)
        let key = try PKCS5.PBKDF2(
            password: Array(passphrase.utf8),
            salt: salt,
            iterations: 210_000,
            keyLength: 32,
            variant: .sha2(.sha256)
        ).calculate()

        let encrypted = try AEADXChaCha20Poly1305.encrypt(
            [UInt8](compressed),
            key: key,
            iv: nonce,
            authenticationHeader: []
        )

        var output = Data("CSWF".utf8)
        output.append(1)
        output.append(contentsOf: salt)
        output.append(contentsOf: nonce)
        output.append(contentsOf: encrypted.cipherText)
        output.append(contentsOf: encrypted.authenticationTag)
        return output
    }
}
