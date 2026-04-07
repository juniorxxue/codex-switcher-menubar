import CryptoKit
import Darwin
import Foundation

enum OAuthLoginService {
    fileprivate static let issuer = "https://auth.openai.com"
    fileprivate static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let requestedScopes = "openid profile email offline_access"
    private static let defaultPort: UInt16 = 1455
    private static let timeoutInterval: TimeInterval = 300

    static func startLogin(accountName: String) async throws -> OAuthLoginSession {
        DebugLogger.info("oauth-service", "Preparing OAuth login for '\(accountName)'.")
        let pkce = generatePKCECodes()
        let state = generateState()
        let server = try makeReadyServer()
        let redirectURI = "http://localhost:\(server.callbackPort)/auth/callback"
        let authURL = try buildAuthorizeURL(
            redirectURI: redirectURI,
            codeChallenge: pkce.codeChallenge,
            state: state
        )

        let session = OAuthLoginSession(
            accountName: accountName,
            authURL: authURL,
            callbackPort: server.callbackPort,
            redirectURI: redirectURI,
            codeVerifier: pkce.codeVerifier,
            expectedState: state,
            server: server,
            timeoutInterval: timeoutInterval
        )
        DebugLogger.info(
            "oauth-service",
            "OAuth callback server ready on port \(server.callbackPort). Auth URL: \(DebugLogger.sanitizedURL(authURL))"
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
            URLQueryItem(name: "scope", value: requestedScopes),
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

    private static func makeReadyServer() throws -> LocalCallbackServer {
        do {
            DebugLogger.info("oauth-service", "Attempting to bind OAuth callback server on default port \(defaultPort).")
            return try startServer(on: defaultPort)
        } catch {
            let defaultError = error
            DebugLogger.error(
                "oauth-service",
                "Failed to bind OAuth callback server on default port \(defaultPort): \(defaultError.localizedDescription)"
            )

            if isAddressInUse(defaultError) {
                do {
                    DebugLogger.info("oauth-service", "Default OAuth callback port is busy. Falling back to a random local port.")
                    return try startServer(on: nil)
                } catch {
                    DebugLogger.error(
                        "oauth-service",
                        "Random local port fallback for OAuth callback server failed: \(error.localizedDescription)"
                    )
                    if let owner = activeListener(on: defaultPort) {
                        throw AppError(
                            message: """
                            Port \(defaultPort) is already in use by \(owner.displayName). Random local port fallback also failed: \(error.localizedDescription)
                            """
                        )
                    }

                    throw AppError(
                        message: """
                        Failed to start local OAuth callback server. Default port \(defaultPort) failed: \(defaultError.localizedDescription). Random local port fallback also failed: \(error.localizedDescription)
                        """
                    )
                }
            }

            throw AppError(
                message: "Failed to start local OAuth callback server on port \(defaultPort): \(defaultError.localizedDescription)"
            )
        }
    }

    private static func startServer(on port: UInt16?) throws -> LocalCallbackServer {
        let listenSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard listenSocket >= 0 else {
            throw LocalSocketServerError(operation: "Failed to create local OAuth callback server socket", code: errno)
        }

        var shouldCloseSocket = true
        defer {
            if shouldCloseSocket {
                _ = close(listenSocket)
            }
        }

        var reuseAddress: Int32 = 1
        if setsockopt(
            listenSocket,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) != 0 {
            throw LocalSocketServerError(operation: "Failed to configure local OAuth callback server socket", code: errno)
        }

        var noSigPipe: Int32 = 1
        _ = setsockopt(
            listenSocket,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t((port ?? 0).bigEndian)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw AppError(message: "Failed to configure local OAuth callback server address.")
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listenSocket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        if bindResult != 0 {
            throw LocalSocketServerError(operation: "Failed to bind local OAuth callback server", code: errno)
        }

        if listen(listenSocket, SOMAXCONN) != 0 {
            throw LocalSocketServerError(operation: "Failed to listen for OAuth callback connections", code: errno)
        }

        let currentFlags = fcntl(listenSocket, F_GETFL)
        if currentFlags >= 0, fcntl(listenSocket, F_SETFL, currentFlags | O_NONBLOCK) != 0 {
            throw LocalSocketServerError(operation: "Failed to configure local OAuth callback server", code: errno)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let sockNameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(listenSocket, sockaddrPointer, &boundAddressLength)
            }
        }
        if sockNameResult != 0 {
            throw LocalSocketServerError(operation: "Failed to determine OAuth callback port", code: errno)
        }

        let callbackPort = UInt16(bigEndian: boundAddress.sin_port)
        let queue = DispatchQueue(label: "CodexSwitcherMenubar.OAuth.\(UUID().uuidString)")
        let server = LocalCallbackServer(listenSocket: listenSocket, callbackPort: callbackPort, queue: queue)
        DebugLogger.info("oauth-service", "Bound local OAuth callback server on port \(callbackPort).")
        shouldCloseSocket = false
        return server
    }

    private static func isAddressInUse(_ error: Error) -> Bool {
        if let socketError = error as? LocalSocketServerError {
            return socketError.code == EADDRINUSE
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EADDRINUSE) {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EADDRINUSE)
        {
            return true
        }

        return false
    }

    private static func activeListener(on port: UInt16) -> ListeningProcess? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [
            "-nP",
            "-iTCP:\(port)",
            "-sTCP:LISTEN",
            "-Fpc"
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        return parseListeningProcess(raw, excludingPID: ProcessInfo.processInfo.processIdentifier)
    }

    static func parseListeningProcess(_ raw: String, excludingPID currentPID: Int32? = nil) -> ListeningProcess? {
        var currentPIDValue: Int32?

        for line in raw.split(whereSeparator: \.isNewline) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())

            switch prefix {
            case "p":
                currentPIDValue = Int32(value)
            case "c":
                guard let pid = currentPIDValue else { continue }
                if let currentPID, pid == currentPID {
                    currentPIDValue = nil
                    continue
                }
                return ListeningProcess(pid: pid, command: value)
            default:
                continue
            }
        }

        return nil
    }

    static func userFacingOAuthErrorMessage(error: String, description: String?) -> String {
        if error == "access_denied",
           description?.localizedCaseInsensitiveContains("missing_codex_entitlement") == true
        {
            return "Codex is not enabled for your workspace. Contact your workspace administrator to request access."
        }

        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Sign-in failed: \(description)"
        }

        return "Sign-in failed: \(error)"
    }

    private static func base64URLEncodedString(for data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct ListeningProcess: Equatable {
    let pid: Int32
    let command: String

    var displayName: String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "another process (pid \(pid))"
        }

        return "\(trimmed) (pid \(pid))"
    }
}

final class OAuthLoginSession: @unchecked Sendable {
    let accountName: String
    let authURL: URL
    let callbackPort: UInt16

    private let redirectURI: String
    private let codeVerifier: String
    private let expectedState: String
    private let server: LocalCallbackServer
    private let timeoutInterval: TimeInterval
    private let completion = OAuthResultCompletion()
    private var timeoutWorkItem: DispatchWorkItem?
    private(set) lazy var resultTask: Task<StoredAccount, Error> = Task {
        try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
        }
    }

    fileprivate init(
        accountName: String,
        authURL: URL,
        callbackPort: UInt16,
        redirectURI: String,
        codeVerifier: String,
        expectedState: String,
        server: LocalCallbackServer,
        timeoutInterval: TimeInterval
    ) {
        self.accountName = accountName
        self.authURL = authURL
        self.callbackPort = callbackPort
        self.redirectURI = redirectURI
        self.codeVerifier = codeVerifier
        self.expectedState = expectedState
        self.server = server
        self.timeoutInterval = timeoutInterval
    }

    func start() {
        _ = resultTask
        DebugLogger.info("oauth-callback", "Starting callback server loop on port \(callbackPort).")

        server.failureHandler = { [weak self] error in
            DebugLogger.error("oauth-callback", "Callback server failure on port \(self?.callbackPort ?? 0): \(error.localizedDescription)")
            self?.finish(.failure(AppError(message: "OAuth callback server failed: \(error.localizedDescription)")))
        }

        server.newConnectionHandler = { [weak self] socket in
            guard let self else {
                closeConnection(socket)
                return
            }
            self.handle(connectionSocket: socket)
        }

        server.start()

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(AppError(message: "OAuth login timed out.")))
        }
        self.timeoutWorkItem = timeoutWorkItem
        server.queue.asyncAfter(deadline: .now() + timeoutInterval, execute: timeoutWorkItem)
    }

    func cancel() {
        DebugLogger.info("oauth-callback", "Cancelling callback server on port \(callbackPort).")
        finish(.failure(AppError(message: "OAuth login cancelled.")))
    }

    private func handle(connectionSocket: Int32) {
        do {
            let requestString = try readRequest(from: connectionSocket)
            let requestLine = requestString.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? "<empty>"
            DebugLogger.info("oauth-callback", "Received callback request on port \(callbackPort): \(requestLine)")
            Task {
                await self.processRequest(requestString, on: connectionSocket)
            }
        } catch {
            DebugLogger.error("oauth-callback", "Failed to read callback request on port \(callbackPort): \(error.localizedDescription)")
            respond(
                on: connectionSocket,
                statusCode: 500,
                body: "OAuth callback failed: \(error.localizedDescription)"
            )
            finish(.failure(AppError(message: "OAuth callback failed: \(error.localizedDescription)")))
        }
    }

    private func readRequest(from connectionSocket: Int32) throws -> String {
        configureAcceptedSocket(connectionSocket)

        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while requestData.count < 16_384 {
            let bytesRead = recv(connectionSocket, &buffer, buffer.count, 0)
            if bytesRead > 0 {
                requestData.append(buffer, count: bytesRead)
                if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                    break
                }
                continue
            }

            if bytesRead == 0 {
                break
            }

            if errno == EINTR {
                continue
            }

            throw LocalSocketServerError(operation: "Failed to read OAuth callback request", code: errno)
        }

        return String(data: requestData, encoding: .utf8) ?? ""
    }

    private func configureAcceptedSocket(_ socket: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            socket,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                socket,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.stride)
            )
        }
    }

    private func processRequest(_ requestString: String, on connectionSocket: Int32) async {
        let requestLine = requestString.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            respond(on: connectionSocket, statusCode: 400, body: "Bad Request")
            return
        }

        let pathWithQuery = String(requestParts[1])
        guard let components = URLComponents(string: "http://localhost\(pathWithQuery)") else {
            respond(on: connectionSocket, statusCode: 400, body: "Bad Request")
            return
        }

        guard components.path == "/auth/callback" else {
            respond(on: connectionSocket, statusCode: 404, body: "Not Found")
            return
        }

        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        DebugLogger.info(
            "oauth-callback",
            "Processing callback path \(components.path) on port \(callbackPort). Query keys: \(DebugLogger.querySummary(queryItems))"
        )

        if let error = queryItems["error"], !error.isEmpty {
            let description = queryItems["error_description"] ?? "Unknown error"
            let message = OAuthLoginService.userFacingOAuthErrorMessage(error: error, description: description)
            DebugLogger.error("oauth-callback", "OAuth provider returned error '\(error)': \(description)")
            respond(on: connectionSocket, statusCode: 400, body: message)
            finish(.failure(AppError(message: message)))
            return
        }

        guard queryItems["state"] == expectedState else {
            DebugLogger.error("oauth-callback", "OAuth callback state mismatch on port \(callbackPort).")
            respond(on: connectionSocket, statusCode: 400, body: "State mismatch")
            finish(.failure(AppError(message: "OAuth state mismatch.")))
            return
        }

        guard let code = queryItems["code"], !code.isEmpty else {
            DebugLogger.error("oauth-callback", "OAuth callback missing authorization code on port \(callbackPort).")
            respond(on: connectionSocket, statusCode: 400, body: "Missing authorization code")
            finish(.failure(AppError(message: "Missing authorization code.")))
            return
        }

        do {
            DebugLogger.info("oauth-callback", "Exchanging OAuth code for tokens on port \(callbackPort).")
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

            DebugLogger.info(
                "oauth-callback",
                "OAuth token exchange succeeded for '\(accountName)'. Email: \(claims.email ?? "<missing>")."
            )
            respond(on: connectionSocket, statusCode: 200, body: successHTML, contentType: "text/html; charset=utf-8")
            finish(.success(account))
        } catch {
            DebugLogger.error("oauth-callback", "OAuth token exchange failed for '\(accountName)': \(error.localizedDescription)")
            respond(on: connectionSocket, statusCode: 500, body: "Token exchange failed: \(error.localizedDescription)")
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

        DebugLogger.info("oauth-token", "Sending token exchange request for callback port \(callbackPort).")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            DebugLogger.error("oauth-token", "Token exchange returned no HTTP response.")
            throw AppError(message: "No HTTP response during token exchange.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown response body"
            DebugLogger.error("oauth-token", "Token exchange failed with status \(httpResponse.statusCode): \(bodyText)")
            throw AppError(message: "Token exchange failed (\(httpResponse.statusCode)): \(bodyText)")
        }

        DebugLogger.info("oauth-token", "Token exchange completed with status \(httpResponse.statusCode).")
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }

    private func respond(
        on connectionSocket: Int32,
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
        sendAll(responseData, to: connectionSocket)
        closeConnection(connectionSocket)
    }

    private func finish(_ result: Result<StoredAccount, Error>) {
        timeoutWorkItem?.cancel()
        server.cancel()
        switch result {
        case .success(let account):
            DebugLogger.info("oauth-callback", "Finishing OAuth session successfully for '\(account.name)' on port \(callbackPort).")
        case .failure(let error):
            DebugLogger.error("oauth-callback", "Finishing OAuth session with error on port \(callbackPort): \(error.localizedDescription)")
        }
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

private final class LocalCallbackServer: @unchecked Sendable {
    let callbackPort: UInt16
    let queue: DispatchQueue

    var newConnectionHandler: ((Int32) -> Void)?
    var failureHandler: ((Error) -> Void)?

    private let lock = NSLock()
    private var listenSocket: Int32
    private var acceptSource: DispatchSourceRead?

    init(listenSocket: Int32, callbackPort: UInt16, queue: DispatchQueue) {
        self.listenSocket = listenSocket
        self.callbackPort = callbackPort
        self.queue = queue
    }

    func start() {
        lock.lock()
        guard acceptSource == nil else {
            lock.unlock()
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenSocket, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler { [weak self] in
            self?.closeListenSocket()
        }
        acceptSource = source
        lock.unlock()

        DebugLogger.info("oauth-server", "Dispatch source resumed for local callback server on port \(callbackPort).")
        source.resume()
    }

    func cancel() {
        DebugLogger.info("oauth-server", "Cancelling local callback server on port \(callbackPort).")
        lock.lock()
        let source = acceptSource
        acceptSource = nil
        lock.unlock()

        if let source {
            source.cancel()
        } else {
            closeListenSocket()
        }
    }

    private func acceptConnections() {
        while true {
            var address = sockaddr_storage()
            var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.stride)
            let connectionSocket = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(listenSocket, sockaddrPointer, &addressLength)
                }
            }

            if connectionSocket >= 0 {
                DebugLogger.info("oauth-server", "Accepted local callback connection on port \(callbackPort).")
                newConnectionHandler?(connectionSocket)
                continue
            }

            if errno == EWOULDBLOCK || errno == EAGAIN {
                break
            }

            let error = LocalSocketServerError(operation: "Failed to accept OAuth callback connection", code: errno)
            DebugLogger.error("oauth-server", error.localizedDescription)
            failureHandler?(error)
            break
        }
    }

    private func closeListenSocket() {
        lock.lock()
        let socket = listenSocket
        listenSocket = -1
        lock.unlock()

        guard socket >= 0 else {
            return
        }

        _ = shutdown(socket, SHUT_RDWR)
        _ = close(socket)
    }
}

private struct LocalSocketServerError: LocalizedError {
    let operation: String
    let code: Int32

    var errorDescription: String? {
        "\(operation): \(String(cString: strerror(code)))"
    }
}

private func closeConnection(_ socket: Int32) {
    guard socket >= 0 else {
        return
    }

    _ = shutdown(socket, SHUT_RDWR)
    _ = close(socket)
}

private func sendAll(_ data: Data, to socket: Int32) {
    data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return
        }

        var sent = 0
        while sent < bytes.count {
            let result = send(socket, baseAddress.advanced(by: sent), bytes.count - sent, 0)
            if result > 0 {
                sent += result
                continue
            }

            if result == -1 && errno == EINTR {
                continue
            }

            break
        }
    }
}
