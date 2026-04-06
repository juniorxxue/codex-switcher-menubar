import CryptoKit
import Foundation
import Network

enum OAuthLoginService {
    fileprivate static let issuer = "https://auth.openai.com"
    fileprivate static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let defaultPort: UInt16 = 1455
    private static let timeoutInterval: TimeInterval = 300

    static func startLogin(accountName: String) async throws -> OAuthLoginSession {
        let pkce = generatePKCECodes()
        let state = generateState()
        let (listener, queue, callbackPort) = try await makeReadyListener()
        let redirectURI = "http://localhost:\(callbackPort)/auth/callback"
        let authURL = try buildAuthorizeURL(
            redirectURI: redirectURI,
            codeChallenge: pkce.codeChallenge,
            state: state
        )

        let session = OAuthLoginSession(
            accountName: accountName,
            authURL: authURL,
            callbackPort: callbackPort,
            redirectURI: redirectURI,
            codeVerifier: pkce.codeVerifier,
            expectedState: state,
            listener: listener,
            queue: queue,
            timeoutInterval: timeoutInterval
        )
        session.start()
        return session
    }

    private static func generatePKCECodes() -> (codeVerifier: String, codeChallenge: String) {
        let verifierData = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let codeVerifier = base64URLEncodedString(for: verifierData)
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        let codeChallenge = base64URLEncodedString(for: Data(digest))
        return (codeVerifier, codeChallenge)
    }

    private static func generateState() -> String {
        let stateData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return base64URLEncodedString(for: stateData)
    }

    private static func buildAuthorizeURL(
        redirectURI: String,
        codeChallenge: String,
        state: String
    ) throws -> URL {
        var components = URLComponents(string: "\(issuer)/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "codex_cli_rs")
        ]

        guard let url = components?.url else {
            throw AppError(message: "Failed to build ChatGPT login URL.")
        }

        return url
    }

    private static func makeReadyListener() async throws -> (NWListener, DispatchQueue, UInt16) {
        do {
            return try await startListener(on: defaultPort)
        } catch {
            return try await startListener(on: nil)
        }
    }

    private static func startListener(on port: UInt16?) async throws -> (NWListener, DispatchQueue, UInt16) {
        let listener: NWListener
        do {
            if let port, let endpointPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: .tcp, on: endpointPort)
            } else {
                listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: 0)!)
            }
        } catch {
            throw AppError(message: "Failed to start local OAuth callback server: \(error.localizedDescription)")
        }

        let queue = DispatchQueue(label: "CodexSwitcherMenubar.OAuth.\(UUID().uuidString)")

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OAuthContinuationGuard()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let callbackPort = listener.port?.rawValue else {
                        resumed.resume(continuation) {
                            .failure(AppError(message: "Failed to determine OAuth callback port."))
                        }
                        return
                    }

                    resumed.resume(continuation) {
                        .success((listener, queue, callbackPort))
                    }

                case .failed(let error):
                    resumed.resume(continuation) {
                        .failure(AppError(message: "Failed to start local OAuth callback server: \(error.localizedDescription)"))
                    }

                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    private static func base64URLEncodedString(for data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class OAuthLoginSession: @unchecked Sendable {
    let accountName: String
    let authURL: URL
    let callbackPort: UInt16

    private let redirectURI: String
    private let codeVerifier: String
    private let expectedState: String
    private let listener: NWListener
    private let queue: DispatchQueue
    private let timeoutInterval: TimeInterval
    private let completion = OAuthResultCompletion()
    private var timeoutWorkItem: DispatchWorkItem?
    private(set) lazy var resultTask: Task<StoredAccount, Error> = Task {
        try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
        }
    }

    init(
        accountName: String,
        authURL: URL,
        callbackPort: UInt16,
        redirectURI: String,
        codeVerifier: String,
        expectedState: String,
        listener: NWListener,
        queue: DispatchQueue,
        timeoutInterval: TimeInterval
    ) {
        self.accountName = accountName
        self.authURL = authURL
        self.callbackPort = callbackPort
        self.redirectURI = redirectURI
        self.codeVerifier = codeVerifier
        self.expectedState = expectedState
        self.listener = listener
        self.queue = queue
        self.timeoutInterval = timeoutInterval
    }

    func start() {
        _ = resultTask

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.finish(.failure(AppError(message: "OAuth callback server failed: \(error.localizedDescription)")))
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(AppError(message: "OAuth login timed out.")))
        }
        self.timeoutWorkItem = timeoutWorkItem
        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: timeoutWorkItem)
    }

    func cancel() {
        finish(.failure(AppError(message: "OAuth login cancelled.")))
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulatedData: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.respond(
                    on: connection,
                    statusCode: 500,
                    body: "OAuth callback failed: \(error.localizedDescription)"
                )
                self.finish(.failure(AppError(message: "OAuth callback failed: \(error.localizedDescription)")))
                return
            }

            let combinedData = accumulatedData + (data ?? Data())
            let requestString = String(data: combinedData, encoding: .utf8) ?? ""

            if requestString.contains("\r\n\r\n") || isComplete {
                Task {
                    await self.processRequest(requestString, on: connection)
                }
            } else {
                self.receiveRequest(on: connection, accumulatedData: combinedData)
            }
        }
    }

    private func processRequest(_ requestString: String, on connection: NWConnection) async {
        let requestLine = requestString.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            respond(on: connection, statusCode: 400, body: "Bad Request")
            return
        }

        let pathWithQuery = String(requestParts[1])
        guard let components = URLComponents(string: "http://localhost\(pathWithQuery)") else {
            respond(on: connection, statusCode: 400, body: "Bad Request")
            return
        }

        guard components.path == "/auth/callback" else {
            respond(on: connection, statusCode: 404, body: "Not Found")
            return
        }

        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if let error = queryItems["error"], !error.isEmpty {
            let description = queryItems["error_description"] ?? "Unknown error"
            respond(on: connection, statusCode: 400, body: "OAuth Error: \(error) - \(description)")
            finish(.failure(AppError(message: "OAuth error: \(error) - \(description)")))
            return
        }

        guard queryItems["state"] == expectedState else {
            respond(on: connection, statusCode: 400, body: "State mismatch")
            finish(.failure(AppError(message: "OAuth state mismatch.")))
            return
        }

        guard let code = queryItems["code"], !code.isEmpty else {
            respond(on: connection, statusCode: 400, body: "Missing authorization code")
            finish(.failure(AppError(message: "Missing authorization code.")))
            return
        }

        do {
            let tokenResponse = try await exchangeCodeForTokens(code: code)
            let claims = JWT.decodeClaims(from: tokenResponse.idToken)
            let account = StoredAccount.makeChatGPT(
                name: accountName,
                email: claims.email,
                planType: claims.planType,
                tokens: ChatGPTCredential(
                    idToken: tokenResponse.idToken,
                    accessToken: tokenResponse.accessToken,
                    refreshToken: tokenResponse.refreshToken,
                    accountID: claims.accountID
                )
            )

            respond(on: connection, statusCode: 200, body: successHTML, contentType: "text/html; charset=utf-8")
            finish(.success(account))
        } catch {
            respond(on: connection, statusCode: 500, body: "Token exchange failed: \(error.localizedDescription)")
            finish(.failure(error))
        }
    }

    private func exchangeCodeForTokens(code: String) async throws -> OAuthTokenResponse {
        guard let tokenURL = URL(string: "\(OAuthLoginService.issuer)/oauth/token") else {
            throw AppError(message: "Invalid ChatGPT token URL.")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "code=\(urlEncode(code))",
            "redirect_uri=\(urlEncode(redirectURI))",
            "client_id=\(urlEncode(OAuthLoginService.clientID))",
            "code_verifier=\(urlEncode(codeVerifier))"
        ]
        .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(message: "No HTTP response during token exchange.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown response body"
            throw AppError(message: "Token exchange failed (\(httpResponse.statusCode)): \(bodyText)")
        }

        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }

    private func respond(
        on connection: NWConnection,
        statusCode: Int,
        body: String,
        contentType: String = "text/plain; charset=utf-8"
    ) {
        let bodyData = Data(body.utf8)
        let response = """
        HTTP/1.1 \(statusCode) \(httpStatusText(for: statusCode))
        Content-Type: \(contentType)
        Content-Length: \(bodyData.count)
        Connection: close

        """

        let responseData = Data(response.utf8) + bodyData
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<StoredAccount, Error>) {
        timeoutWorkItem?.cancel()
        listener.cancel()
        completion.resume(with: result)
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func httpStatusText(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        default:
            return "Internal Server Error"
        }
    }

    private var successHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Login Successful</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f7; color: #1d1d1f; }
                .card { background: white; border-radius: 18px; padding: 32px 40px; box-shadow: 0 18px 48px rgba(0,0,0,0.08); text-align: center; max-width: 420px; }
                .check { font-size: 42px; color: #16a34a; margin-bottom: 12px; }
                h1 { margin: 0 0 8px; font-size: 24px; }
                p { margin: 0; color: #6e6e73; }
            </style>
        </head>
        <body>
            <div class="card">
                <div class="check">✓</div>
                <h1>Account Added</h1>
                <p>You can close this window and return to Codex Switcher Menubar.</p>
            </div>
        </body>
        </html>
        """
    }
}

private struct OAuthTokenResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private final class OAuthResultCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<StoredAccount, Error>?
    private var pendingResult: Result<StoredAccount, Error>?

    func install(_ continuation: CheckedContinuation<StoredAccount, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }

        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<StoredAccount, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }

        if pendingResult == nil {
            pendingResult = result
        }
        lock.unlock()
    }
}

private final class OAuthContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resume<T>(
        _ continuation: CheckedContinuation<T, Error>,
        with result: () -> Result<T, Error>
    ) {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return
        }
        hasResumed = true
        lock.unlock()
        continuation.resume(with: result())
    }
}
