import AppKit
import CryptoSwift
import Foundation
import UniformTypeIdentifiers
import zlib

enum AppPaths {
    private static let appFolderName = "CodexSwitcherMenubar"

    static var storageDirectory: URL {
        if let explicit = ProcessInfo.processInfo.environment["CODEX_SWITCHER_MENUBAR_STORAGE_DIR"],
           !explicit.isEmpty
        {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }

        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return root.appendingPathComponent(appFolderName, isDirectory: true)
    }

    static var storeFile: URL {
        storageDirectory.appendingPathComponent("accounts.json")
    }

    static var usageHistoryFile: URL {
        storageDirectory.appendingPathComponent("usage-history.json")
    }

    static var debugLogFile: URL {
        if let explicit = ProcessInfo.processInfo.environment["CODEX_SWITCHER_MENUBAR_LOG_FILE"],
           !explicit.isEmpty
        {
            return URL(fileURLWithPath: explicit, isDirectory: false)
        }

        return storageDirectory.appendingPathComponent("debug.log")
    }

    static var codexHome: URL {
        if let explicit = ProcessInfo.processInfo.environment["CODEX_HOME"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static var codexAuthFile: URL {
        codexHome.appendingPathComponent("auth.json")
    }

    static func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    static func revealStorageDirectory() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([storageDirectory])
    }
}

enum DebugLogger {
    private static let queue = DispatchQueue(label: "CodexSwitcherMenubar.DebugLogger")
    private static let maxLogBytes = 1_000_000
    private static let state = DebugLoggerState()

    static var logFileURL: URL {
        AppPaths.debugLogFile
    }

    static func isEnabled(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let rawValue = environment["CODEX_SWITCHER_MENUBAR_DEBUG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(rawValue)
    }

    static func startSession() {
        guard isEnabled() else { return }
        queue.async {
            prepareLogFileIfNeeded()
            guard !state.hasStartedSession else { return }
            state.hasStartedSession = true
            append("INFO", category: "app", message: "Starting session. Log file: \(logFileURL.path)")
        }
    }

    static func info(_ category: String, _ message: String) {
        log(level: "INFO", category: category, message: message)
    }

    static func error(_ category: String, _ message: String) {
        log(level: "ERROR", category: category, message: message)
    }

    static func log(level: String, category: String, message: String) {
        guard isEnabled() else { return }
        queue.async {
            prepareLogFileIfNeeded()
            append(level, category: category, message: message)
        }
    }

    static func sanitizedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else {
            return url.absoluteString
        }

        let sensitiveKeys = Set([
            "access_token",
            "code",
            "code_verifier",
            "id_token",
            "refresh_token",
            "state",
            "token"
        ])

        components.queryItems = queryItems.map { item in
            guard sensitiveKeys.contains(item.name.lowercased()) else {
                return item
            }
            return URLQueryItem(name: item.name, value: "<redacted>")
        }

        return components.url?.absoluteString ?? url.absoluteString
    }

    static func querySummary(_ queryItems: [String: String]) -> String {
        let interesting = queryItems.keys.sorted().joined(separator: ",")
        return interesting.isEmpty ? "<none>" : interesting
    }

    private static func append(_ level: String, category: String, message: String) {
        let timestamp = makeISO8601Formatter(withFractionalSeconds: true).string(from: Date())
        let line = "\(timestamp) [\(level)] [\(category)] \(message)\n"

        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFileURL, options: [.atomic])
            }
        }

        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func prepareLogFileIfNeeded() {
        try? AppPaths.ensureParentDirectory(for: logFileURL)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue > maxLogBytes
        {
            try? FileManager.default.removeItem(at: logFileURL)
        }

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            try? LocalStore.setRestrictedPermissions(logFileURL)
        }
    }
}

private final class DebugLoggerState: @unchecked Sendable {
    var hasStartedSession = false
}

enum JSONCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }

            let string = try container.decode(String.self)
            if let date = makeISO8601Formatter(withFractionalSeconds: true).date(from: string)
                ?? makeISO8601Formatter(withFractionalSeconds: false).date(from: string)
            {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported date format: \(string)"
            )
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeISO8601Formatter(withFractionalSeconds: true).string(from: date))
        }
        return encoder
    }
}

func makeISO8601Formatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = withFractionalSeconds
        ? [.withInternetDateTime, .withFractionalSeconds]
        : [.withInternetDateTime]
    return formatter
}

enum LocalStore {
    static func load() throws -> AccountsStore {
        let fileURL = AppPaths.storeFile
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AccountsStore()
        }

        let data = try Data(contentsOf: fileURL)
        if let store = try? JSONCoding.decoder().decode(AccountsStore.self, from: data) {
            return store
        }

        let legacyStore = try JSONCoding.decoder().decode(LegacyAccountsStore.self, from: data)
        return legacyStore.toInternalStore()
    }

    static func save(_ store: AccountsStore) throws {
        let data = try JSONCoding.encoder().encode(store)
        try AppPaths.ensureParentDirectory(for: AppPaths.storeFile)
        try data.write(to: AppPaths.storeFile, options: [.atomic])
        try setRestrictedPermissions(AppPaths.storeFile)
    }

    static func setRestrictedPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

enum CodexSwitcherExportService {
    private static let fullFileMagic = Data("CSWF".utf8)
    private static let fullFileVersion: UInt8 = 1
    private static let fullSaltLength = 16
    private static let fullNonceLength = 24
    private static let fullTagLength = 16
    private static let fullHeaderLength = 4 + 1 + fullSaltLength + fullNonceLength
    private static let fullPresetPassphrase = "gT7kQ9mV2xN4pL8sR1dH6zW3cB5yF0uJ_aE7nK2tP9vM4rX1"
    private static let fullKDFIterations = 210_000
    private static let maxImportFileBytes = 8 * 1024 * 1024
    private static let maxImportJSONBytes = 2 * 1024 * 1024

    static func importFullExport(from url: URL) throws -> AccountsStore {
        let data = try Data(contentsOf: url)
        return try decodeFullEncryptedStore(data)
    }

    static func decodeFullEncryptedStore(_ fileBytes: Data) throws -> AccountsStore {
        guard fileBytes.count <= maxImportFileBytes else {
            throw AppError(message: "Encrypted file is too large.")
        }

        guard fileBytes.count > fullHeaderLength + fullTagLength else {
            throw AppError(message: "Encrypted file is invalid or truncated.")
        }

        guard fileBytes.prefix(4) == fullFileMagic else {
            throw AppError(message: "Encrypted file header is invalid.")
        }

        let version = fileBytes[fileBytes.startIndex + 4]
        guard version == fullFileVersion else {
            throw AppError(message: "Unsupported encrypted file version: \(version).")
        }

        let saltStart = 5
        let nonceStart = saltStart + fullSaltLength
        let ciphertextStart = nonceStart + fullNonceLength

        let salt = Array(fileBytes[saltStart..<nonceStart])
        let nonce = Array(fileBytes[nonceStart..<ciphertextStart])
        let encryptedBytes = Array(fileBytes[ciphertextStart...])

        guard encryptedBytes.count > fullTagLength else {
            throw AppError(message: "Encrypted file is missing authentication data.")
        }

        let ciphertext = Array(encryptedBytes.dropLast(fullTagLength))
        let authenticationTag = Array(encryptedBytes.suffix(fullTagLength))

        let key = try PKCS5.PBKDF2(
            password: Array(fullPresetPassphrase.utf8),
            salt: salt,
            iterations: fullKDFIterations,
            keyLength: 32,
            variant: .sha2(.sha256)
        ).calculate()

        let decrypted = try AEADXChaCha20Poly1305.decrypt(
            ciphertext,
            key: key,
            iv: nonce,
            authenticationHeader: [],
            authenticationTag: authenticationTag
        )

        guard decrypted.success else {
            throw AppError(message: "Failed to decrypt file.")
        }

        let compressedPayload = Data(decrypted.plainText)
        let jsonData = try decompressZlibPayload(compressedPayload)

        if let store = try? JSONCoding.decoder().decode(AccountsStore.self, from: jsonData) {
            return store
        }

        let legacyStore = try JSONCoding.decoder().decode(LegacyAccountsStore.self, from: jsonData)
        return legacyStore.toInternalStore()
    }

    private static func decompressZlibPayload(_ data: Data) throws -> Data {
        let bufferSize = 64 * 1024
        var stream = z_stream()
        var status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw AppError(message: "Failed to initialize decompression.")
        }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { rawBuffer -> Data in
            guard let sourcePointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Data()
            }

            stream.next_in = UnsafeMutablePointer(mutating: sourcePointer)
            stream.avail_in = uInt(data.count)

            var output = Data()
            output.reserveCapacity(min(data.count * 2, maxImportJSONBytes))

            repeat {
                var chunk = [UInt8](repeating: 0, count: bufferSize)
                let produced = try chunk.withUnsafeMutableBufferPointer { buffer -> Int in
                    guard let destinationPointer = buffer.baseAddress else {
                        return 0
                    }

                    stream.next_out = destinationPointer
                    stream.avail_out = uInt(buffer.count)
                    status = inflate(&stream, Z_NO_FLUSH)

                    switch status {
                    case Z_OK, Z_STREAM_END:
                        return buffer.count - Int(stream.avail_out)
                    default:
                        throw AppError(message: "Failed to decompress decrypted payload.")
                    }
                }

                if produced > 0 {
                    output.append(chunk, count: produced)
                    if output.count > maxImportJSONBytes {
                        throw AppError(message: "Import data is too large.")
                    }
                }
            } while status != Z_STREAM_END

            return output
        }
    }
}

struct LegacyAccountsStore: Codable {
    var version: Int
    var accounts: [LegacyStoredAccount]
    var activeAccountID: String?
    var maskedAccountIDs: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case accounts
        case activeAccountID = "active_account_id"
        case maskedAccountIDs = "masked_account_ids"
    }

    init(from store: AccountsStore) {
        version = store.version
        accounts = store.accounts.map(LegacyStoredAccount.init)
        activeAccountID = store.activeAccountID?.uuidString
        maskedAccountIDs = store.maskedAccountIDs
    }

    func toInternalStore() -> AccountsStore {
        AccountsStore(
            version: version,
            activeAccountID: activeAccountID.flatMap(UUID.init(uuidString:)),
            accounts: accounts.map { $0.toInternalAccount() },
            maskedAccountIDs: maskedAccountIDs
        )
    }
}

struct LegacyStoredAccount: Codable {
    var id: String
    var name: String
    var email: String?
    var planType: String?
    var authMode: LegacyAuthMode
    var authData: LegacyAuthData
    var createdAt: Date
    var lastUsedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case email
        case planType = "plan_type"
        case authMode = "auth_mode"
        case authData = "auth_data"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    init(_ account: StoredAccount) {
        id = account.id.uuidString
        name = account.name
        email = account.email
        planType = account.planType
        authMode = account.authMode == .chatGPT ? .chatGPT : .apiKey
        createdAt = account.createdAt
        lastUsedAt = account.lastUsedAt

        switch account.authMode {
        case .apiKey:
            authData = .apiKey(key: account.apiKey ?? "")
        case .chatGPT:
            let chatGPT = account.chatGPT ?? ChatGPTCredential(
                idToken: "",
                accessToken: "",
                refreshToken: "",
                accountID: nil
            )
            authData = .chatGPT(
                idToken: chatGPT.idToken,
                accessToken: chatGPT.accessToken,
                refreshToken: chatGPT.refreshToken,
                accountID: chatGPT.accountID
            )
        }
    }

    func toInternalAccount() -> StoredAccount {
        let internalID = UUID(uuidString: id) ?? UUID()

        switch authData {
        case let .apiKey(key):
            return StoredAccount(
                id: internalID,
                name: name,
                email: email,
                planType: planType,
                authMode: .apiKey,
                apiKey: key,
                chatGPT: nil,
                createdAt: createdAt,
                lastUsedAt: lastUsedAt
            )

        case let .chatGPT(idToken, accessToken, refreshToken, accountID):
            return StoredAccount(
                id: internalID,
                name: name,
                email: email,
                planType: planType,
                authMode: .chatGPT,
                apiKey: nil,
                chatGPT: ChatGPTCredential(
                    idToken: idToken,
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    accountID: accountID
                ),
                createdAt: createdAt,
                lastUsedAt: lastUsedAt
            )
        }
    }
}

enum LegacyAuthMode: String, Codable {
    case apiKey = "api_key"
    case chatGPT = "chat_g_p_t"
}

enum LegacyAuthData: Codable {
    case apiKey(key: String)
    case chatGPT(idToken: String, accessToken: String, refreshToken: String, accountID: String?)

    enum CodingKeys: String, CodingKey {
        case type
        case key
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }

    enum Kind: String, Codable {
        case apiKey = "api_key"
        case chatGPT = "chat_g_p_t"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)

        switch kind {
        case .apiKey:
            self = .apiKey(key: try container.decode(String.self, forKey: .key))

        case .chatGPT:
            self = .chatGPT(
                idToken: try container.decode(String.self, forKey: .idToken),
                accessToken: try container.decode(String.self, forKey: .accessToken),
                refreshToken: try container.decode(String.self, forKey: .refreshToken),
                accountID: try container.decodeIfPresent(String.self, forKey: .accountID)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .apiKey(key):
            try container.encode(Kind.apiKey, forKey: .type)
            try container.encode(key, forKey: .key)

        case let .chatGPT(idToken, accessToken, refreshToken, accountID):
            try container.encode(Kind.chatGPT, forKey: .type)
            try container.encode(idToken, forKey: .idToken)
            try container.encode(accessToken, forKey: .accessToken)
            try container.encode(refreshToken, forKey: .refreshToken)
            try container.encodeIfPresent(accountID, forKey: .accountID)
        }
    }
}

enum AuthFileService {
    static func importCurrentCodexAuth(named name: String) throws -> StoredAccount {
        try importAuthFile(at: AppPaths.codexAuthFile, named: name)
    }

    static func importAuthFile(at url: URL, named name: String) throws -> StoredAccount {
        let data = try Data(contentsOf: url)
        return try importAuthData(data, named: name)
    }

    static func importAuthJSONString(_ json: String, named name: String) throws -> StoredAccount {
        let data = Data(json.utf8)
        return try importAuthData(data, named: name)
    }

    static func importAuthData(_ data: Data, named name: String) throws -> StoredAccount {
        let auth = try JSONCoding.decoder().decode(AuthJSON.self, from: data)

        if let apiKey = auth.openAIAPIKey, !apiKey.isEmpty {
            throw AppError(message: "API-key auth files are not supported here. Add a ChatGPT subscription account instead.")
        }

        guard let tokens = auth.tokens else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSDebugDescriptionErrorKey: "auth.json is missing ChatGPT tokens."
            ])
        }

        let claims = JWT.decodeClaims(from: tokens.idToken)
        let credential = ChatGPTCredential(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            accountID: tokens.accountID ?? claims.accountID
        )

        return StoredAccount.makeChatGPT(
            name: name,
            email: claims.email,
            planType: claims.planType,
            tokens: credential
        )
    }

    static func writeCurrentAuth(for account: StoredAccount) throws {
        let authJSON: AuthJSON

        switch account.authMode {
        case .apiKey:
            guard let apiKey = account.apiKey, !apiKey.isEmpty else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSDebugDescriptionErrorKey: "Missing API key for \(account.name)."
                ])
            }
            authJSON = AuthJSON(openAIAPIKey: apiKey, tokens: nil, lastRefresh: nil)

        case .chatGPT:
            guard let chatGPT = account.chatGPT else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSDebugDescriptionErrorKey: "Missing ChatGPT tokens for \(account.name)."
                ])
            }
            authJSON = AuthJSON(
                openAIAPIKey: nil,
                tokens: AuthTokens(
                    idToken: chatGPT.idToken,
                    accessToken: chatGPT.accessToken,
                    refreshToken: chatGPT.refreshToken,
                    accountID: chatGPT.accountID
                ),
                lastRefresh: Date()
            )
        }

        let fileURL = AppPaths.codexAuthFile
        try AppPaths.ensureParentDirectory(for: fileURL)
        let data = try JSONCoding.encoder().encode(authJSON)
        try data.write(to: fileURL, options: [.atomic])
        try LocalStore.setRestrictedPermissions(fileURL)
    }

    static func clearCurrentAuth() throws {
        let fileURL = AppPaths.codexAuthFile
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

enum JWT {
    static func decodeClaims(from token: String) -> JWTClaims {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            return JWTClaims()
        }

        guard let payloadData = decodeBase64URL(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return JWTClaims()
        }

        let authClaims = object["https://api.openai.com/auth"] as? [String: Any]

        return JWTClaims(
            email: object["email"] as? String,
            planType: authClaims?["chatgpt_plan_type"] as? String,
            accountID: authClaims?["chatgpt_account_id"] as? String,
            exp: object["exp"] as? Int
        )
    }

    static func decodeBase64URL(_ input: String) -> Data? {
        var value = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = value.count % 4
        if remainder != 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: value)
    }
}

enum TokenRefreshService {
    private static let issuerURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let expirySkewSeconds = 60
    private static let requestTimeout: TimeInterval = 15

    static func ensureFreshTokens(for account: StoredAccount) async throws -> StoredAccount {
        guard account.authMode == .chatGPT, let chatGPT = account.chatGPT else {
            return account
        }

        let claims = JWT.decodeClaims(from: chatGPT.accessToken)
        if let exp = claims.exp, exp <= Int(Date().timeIntervalSince1970) + expirySkewSeconds {
            return try await refreshTokens(for: account)
        }

        return account
    }

    static func refreshTokens(for account: StoredAccount) async throws -> StoredAccount {
        guard account.authMode == .chatGPT, let chatGPT = account.chatGPT else {
            return account
        }

        guard !chatGPT.refreshToken.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSDebugDescriptionErrorKey: "Missing refresh token for \(account.name)."
            ])
        }

        var request = URLRequest(url: issuerURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(urlEncode(chatGPT.refreshToken))",
            "client_id=\(urlEncode(clientID))"
        ]
        .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(message: "No HTTP response when refreshing tokens.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown response body"
            throw AppError(message: "Token refresh failed (\(httpResponse.statusCode)): \(bodyText)")
        }

        let refreshed = try JSONDecoder().decode(RefreshTokenResponse.self, from: data)
        let idToken = refreshed.idToken ?? chatGPT.idToken
        let claims = JWT.decodeClaims(from: idToken)

        let updatedCredential = ChatGPTCredential(
            idToken: idToken,
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? chatGPT.refreshToken,
            accountID: claims.accountID ?? chatGPT.accountID
        )

        var updatedAccount = account
        updatedAccount.chatGPT = updatedCredential
        if let email = claims.email, !email.isEmpty {
            updatedAccount.email = email
        }
        if let planType = claims.planType, !planType.isEmpty {
            updatedAccount.planType = planType
        }
        return updatedAccount
    }

    private static func urlEncode(_ input: String) -> String {
        input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
    }
}

enum UsageService {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let userAgent = "codex-cli/1.0.0"
    private static let requestTimeout: TimeInterval = 15

    static func fetchUsage(for account: StoredAccount) async throws -> AccountUsageResult {
        guard account.authMode == .chatGPT else {
            return AccountUsageResult(
                account: account,
                usage: .unsupportedAPIKey(for: account.id)
            )
        }

        let preparedAccount = try await TokenRefreshService.ensureFreshTokens(for: account)
        let result = try await performUsageRequest(for: preparedAccount)
        return result
    }

    private static func performUsageRequest(for account: StoredAccount) async throws -> AccountUsageResult {
        guard let chatGPT = account.chatGPT else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSDebugDescriptionErrorKey: "ChatGPT credentials are missing for \(account.name)."
            ])
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(chatGPT.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = chatGPT.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(message: "No HTTP response when fetching usage.")
        }

        if httpResponse.statusCode == 401 {
            let refreshedAccount = try await TokenRefreshService.refreshTokens(for: account)
            return try await performUsageRequest(for: refreshedAccount)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown response body"
            throw AppError(message: "Usage request failed (\(httpResponse.statusCode)): \(bodyText)")
        }

        let payload = try JSONDecoder().decode(RateLimitStatusPayload.self, from: data)
        let primary = payload.rateLimit?.primaryWindow
        let secondary = payload.rateLimit?.secondaryWindow

        let usage = UsageInfo(
            accountID: account.id,
            planType: payload.planType,
            primaryUsedPercent: primary?.usedPercent,
            primaryWindowMinutes: primary?.limitWindowSeconds.map { Int((Double($0) / 60).rounded(.up)) },
            primaryResetsAt: primary?.resetAt,
            secondaryUsedPercent: secondary?.usedPercent,
            secondaryWindowMinutes: secondary?.limitWindowSeconds.map { Int((Double($0) / 60).rounded(.up)) },
            secondaryResetsAt: secondary?.resetAt,
            hasCredits: payload.credits?.hasCredits,
            unlimitedCredits: payload.credits?.unlimited,
            creditsBalance: payload.credits?.balance,
            error: nil,
            lastUpdatedAt: Date()
        )

        return AccountUsageResult(account: account, usage: usage)
    }
}

enum CodexProcessService {
    private static let processTimeoutNanoseconds: UInt64 = 1_000_000_000
    private static let processPollIntervalNanoseconds: UInt64 = 50_000_000

    static func runningCodexStatus() -> CodexProcessStatus {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,command="]

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return CodexProcessStatus()
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + processTimeoutNanoseconds
        while task.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: Double(processPollIntervalNanoseconds) / 1_000_000_000)
        }

        if task.isRunning {
            task.terminate()
            return CodexProcessStatus()
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        let pids = output
            .split(separator: "\n")
            .compactMap { line -> Int? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }

                let pieces = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard pieces.count == 2, let pid = Int(pieces[0]) else {
                    return nil
                }

                let command = String(pieces[1])
                let executable = command.split(separator: " ").first.map(String.init) ?? ""
                let isCodex = executable == "codex" || executable.hasSuffix("/codex")
                let isIDEHelper = command.contains(".antigravity")
                    || command.contains("openai.chatgpt")
                    || command.contains(".vscode")

                return isCodex && !isIDEHelper ? pid : nil
            }

        return CodexProcessStatus(pids: Array(Set(pids)).sorted())
    }
}

@MainActor
func chooseAuthFileURL() -> URL? {
    NSApp.activate(ignoringOtherApps: true)

    let panel = NSOpenPanel()
    panel.title = "Choose an auth.json file"
    panel.message = "Import a Codex auth.json file as a reusable account."
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "auth.json"

    return panel.runModal() == .OK ? panel.url : nil
}

@MainActor
func chooseCodexSwitcherExportURL() -> URL? {
    NSApp.activate(ignoringOtherApps: true)

    let panel = NSOpenPanel()
    panel.title = "Choose a Codex Switcher export"
    panel.message = "Import a .cswf full export created by the original Codex Switcher app."
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let exportType = UTType(filenameExtension: "cswf") {
        panel.allowedContentTypes = [exportType]
    }

    return panel.runModal() == .OK ? panel.url : nil
}
