import Foundation

enum AuthMode: String, Codable {
    case apiKey = "api_key"
    case chatGPT = "chatgpt"
}

struct ChatGPTCredential: Codable, Equatable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var accountID: String?
}

struct StoredAccount: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var email: String?
    var planType: String?
    var authMode: AuthMode
    var apiKey: String?
    var chatGPT: ChatGPTCredential?
    var createdAt: Date
    var lastUsedAt: Date?

    var isChatGPT: Bool {
        authMode == .chatGPT
    }

    var subtitle: String {
        if let email, !email.isEmpty {
            return email
        }
        return authMode == .apiKey ? "API key account" : "ChatGPT account"
    }

    var planBadge: String? {
        guard let planType, !planType.isEmpty else {
            return nil
        }
        return planType
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var shortMenuLabel: String {
        let firstWord = name
            .split(separator: " ")
            .first
            .map(String.init) ?? name
        let trimmed = firstWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 6 {
            return trimmed
        }
        return String(trimmed.prefix(6))
    }

    static func makeAPIKey(name: String, apiKey: String) -> StoredAccount {
        StoredAccount(
            id: UUID(),
            name: name,
            email: nil,
            planType: nil,
            authMode: .apiKey,
            apiKey: apiKey,
            chatGPT: nil,
            createdAt: Date(),
            lastUsedAt: nil
        )
    }

    static func makeChatGPT(
        name: String,
        email: String?,
        planType: String?,
        tokens: ChatGPTCredential
    ) -> StoredAccount {
        StoredAccount(
            id: UUID(),
            name: name,
            email: email,
            planType: planType,
            authMode: .chatGPT,
            apiKey: nil,
            chatGPT: tokens,
            createdAt: Date(),
            lastUsedAt: nil
        )
    }
}

struct AccountsStore: Codable {
    var version: Int = 1
    var activeAccountID: UUID?
    var accounts: [StoredAccount] = []
    var maskedAccountIDs: [String] = []
}

struct AuthJSON: Codable {
    var openAIAPIKey: String?
    var tokens: AuthTokens?
    var lastRefresh: Date?

    enum CodingKeys: String, CodingKey {
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

struct AuthTokens: Codable, Equatable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }
}

struct UsageInfo: Equatable {
    var accountID: UUID
    var planType: String?
    var primaryUsedPercent: Double?
    var primaryWindowMinutes: Int?
    var primaryResetsAt: Int?
    var secondaryUsedPercent: Double?
    var secondaryWindowMinutes: Int?
    var secondaryResetsAt: Int?
    var hasCredits: Bool?
    var unlimitedCredits: Bool?
    var creditsBalance: String?
    var error: String?
    var lastUpdatedAt: Date = Date()

    static func unsupportedAPIKey(for accountID: UUID) -> UsageInfo {
        UsageInfo(
            accountID: accountID,
            planType: "api_key",
            primaryUsedPercent: nil,
            primaryWindowMinutes: nil,
            primaryResetsAt: nil,
            secondaryUsedPercent: nil,
            secondaryWindowMinutes: nil,
            secondaryResetsAt: nil,
            hasCredits: nil,
            unlimitedCredits: nil,
            creditsBalance: nil,
            error: "Usage is only available for ChatGPT-based accounts.",
            lastUpdatedAt: Date()
        )
    }

    static func error(for accountID: UUID, message: String) -> UsageInfo {
        UsageInfo(
            accountID: accountID,
            planType: nil,
            primaryUsedPercent: nil,
            primaryWindowMinutes: nil,
            primaryResetsAt: nil,
            secondaryUsedPercent: nil,
            secondaryWindowMinutes: nil,
            secondaryResetsAt: nil,
            hasCredits: nil,
            unlimitedCredits: nil,
            creditsBalance: nil,
            error: message,
            lastUpdatedAt: Date()
        )
    }

    var primaryFraction: Double? {
        guard let primaryUsedPercent else { return nil }
        return max(0, min(primaryUsedPercent / 100, 1))
    }

    var secondaryFraction: Double? {
        guard let secondaryUsedPercent else { return nil }
        return max(0, min(secondaryUsedPercent / 100, 1))
    }
}

struct AccountUsageResult {
    var account: StoredAccount
    var usage: UsageInfo
}

struct RateLimitStatusPayload: Decodable {
    var planType: String
    var rateLimit: RateLimitDetails?
    var credits: CreditStatusDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

struct RateLimitDetails: Decodable {
    var primaryWindow: RateLimitWindow?
    var secondaryWindow: RateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct RateLimitWindow: Decodable {
    var usedPercent: Double
    var limitWindowSeconds: Int?
    var resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

struct CreditStatusDetails: Decodable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

struct RefreshTokenResponse: Decodable {
    var idToken: String?
    var accessToken: String
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct JWTClaims {
    var email: String?
    var planType: String?
    var accountID: String?
    var exp: Int?
}

struct CodexProcessStatus {
    var pids: [Int] = []

    var hasRunningCodex: Bool {
        !pids.isEmpty
    }
}

struct FlashMessage: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var isError: Bool
}

struct PendingOAuthLoginState: Equatable {
    var accountName: String
    var authURL: URL
    var callbackPort: UInt16
}

struct AppError: LocalizedError, Sendable {
    var message: String

    var errorDescription: String? {
        message
    }
}
