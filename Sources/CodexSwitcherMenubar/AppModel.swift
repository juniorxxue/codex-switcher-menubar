import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var store = AccountsStore()
    @Published private(set) var selectedAccountID: UUID?
    @Published private(set) var pendingOAuthLogin: PendingOAuthLoginState?
    @Published private(set) var usageByAccount: [UUID: UsageInfo] = [:]
    @Published private(set) var usageHistoryByAccount: [UUID: [UsageHistoryPoint]] = [:]
    @Published private(set) var refreshingAccountIDs: Set<UUID> = []
    @Published private(set) var processStatus = CodexProcessStatus()
    @Published private(set) var isInitialMenuLoadInProgress = true
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var switchingAccountID: UUID?
    @Published var flashMessage: FlashMessage?

    private let minimumInitialLoadingDelay: TimeInterval = 0.35
    private var clearMessageTask: Task<Void, Never>?
    private var startupRefreshTask: Task<Void, Never>?
    private var oauthCompletionTask: Task<Void, Never>?
    private var hasStartedAppStartup = false
    private var hasStartedStartupRefresh = false
    private let shouldSkipStartupUsageRefresh = ProcessInfo.processInfo.environment["CODEX_SWITCHER_SKIP_STARTUP_REFRESH"] == "1"
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private var oauthLoginSession: OAuthLoginSession?

    var accounts: [StoredAccount] {
        store.accounts.sorted { lhs, rhs in
            let lhsActive = lhs.id == store.activeAccountID
            let rhsActive = rhs.id == store.activeAccountID

            if lhsActive != rhsActive {
                return lhsActive
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var activeAccount: StoredAccount? {
        guard let activeAccountID = store.activeAccountID else {
            return nil
        }
        return store.accounts.first(where: { $0.id == activeAccountID })
    }

    var selectedAccount: StoredAccount? {
        let selectedID = selectedAccountID ?? store.activeAccountID
        guard let selectedID else {
            return store.accounts.first
        }
        return store.accounts.first(where: { $0.id == selectedID }) ?? store.accounts.first
    }

    var menuBarSymbolName: String {
        if flashMessage?.isError == true {
            return "exclamationmark.triangle.fill"
        }

        guard let activeAccount else {
            return "bolt.circle"
        }

        return activeAccount.authMode == .chatGPT
            ? "bolt.circle.fill"
            : "key.fill"
    }

    var menuBarLabelText: String? {
        guard let activeAccount else {
            return nil
        }

        guard activeAccount.authMode == .chatGPT else {
            return activeAccount.shortMenuLabel
        }

        guard let usage = usageByAccount[activeAccount.id],
              usage.error == nil,
              let primaryUsedPercent = usage.primaryUsedPercent
        else {
            return "—"
        }

        return "\(Int(primaryUsedPercent.rounded()))%"
    }

    init() {
        loadStore()
        loadUsageHistory()
        syncSelectionWithStore(preferActive: true)
        scheduleInitialMenuLoadingDismissal()
        DispatchQueue.main.async { [weak self] in
            self?.startStartupRefreshIfNeeded()
        }
    }

    deinit {
        clearMessageTask?.cancel()
    }

    func usageInfo(for accountID: UUID) -> UsageInfo? {
        usageByAccount[accountID]
    }

    func usageHistoryPoints(for accountID: UUID, range: UsageHistoryRange) -> [UsageHistoryPoint] {
        UsageHistoryStore.downsampledPoints(
            for: accountID,
            range: range,
            historyByAccount: usageHistoryByAccount
        )
    }

    func isRefreshing(_ accountID: UUID) -> Bool {
        refreshingAccountIDs.contains(accountID)
    }

    func isActive(_ accountID: UUID) -> Bool {
        store.activeAccountID == accountID
    }

    func isSelected(_ accountID: UUID) -> Bool {
        selectedAccount?.id == accountID
    }

    func selectAccount(_ accountID: UUID) {
        guard store.accounts.contains(where: { $0.id == accountID }) else {
            return
        }

        selectedAccountID = accountID

        if usageByAccount[accountID] == nil,
           !refreshingAccountIDs.contains(accountID)
        {
            Task { @MainActor [weak self] in
                await self?.refreshUsage(for: accountID, announce: false)
            }
        }
    }

    func refreshProcessStatus() async {
        let status = await Task.detached(priority: .utility) {
            CodexProcessService.runningCodexStatus()
        }.value
        processStatus = status
    }

    func start() {
        guard !hasStartedAppStartup else {
            return
        }

        hasStartedAppStartup = true
        syncActiveAuthFileWithStore()

        Task { @MainActor [weak self] in
            await self?.refreshProcessStatus()
        }
    }

    func activateAccount(_ accountID: UUID) async {
        guard let accountIndex = store.accounts.firstIndex(where: { $0.id == accountID }) else {
            postMessage("That account no longer exists.", isError: true)
            return
        }

        guard store.activeAccountID != accountID else {
            do {
                try syncAuthFile(for: store)
            } catch {
                postMessage(error.localizedDescription, isError: true)
            }
            return
        }

        switchingAccountID = accountID
        defer { switchingAccountID = nil }

        let previousStore = store
        let previousActiveAccount = activeAccount
        var updatedStore = store
        updatedStore.activeAccountID = accountID
        updatedStore.accounts[accountIndex].lastUsedAt = Date()
        let normalizedUpdatedStore = normalizedStore(from: updatedStore)

        store = normalizedUpdatedStore
        syncSelectionWithStore(preferActive: true)

        do {
            try syncAuthFile(for: normalizedUpdatedStore)
            try LocalStore.save(normalizedUpdatedStore)

            guard normalizedUpdatedStore.accounts.contains(where: { $0.id == accountID }) else {
                throw AppError(message: "Switched account could not be found after saving.")
            }

            Task { @MainActor [weak self] in
                await self?.refreshProcessStatus()
            }
        } catch {
            store = previousStore
            syncSelectionWithStore(preferActive: true)
            restoreAuthFile(from: previousActiveAccount)
            postMessage(error.localizedDescription, isError: true)
        }
    }

    func refreshUsage(for accountID: UUID, announce: Bool = true) async {
        guard let account = store.accounts.first(where: { $0.id == accountID }) else {
            return
        }

        setRefreshing(true, for: accountID)
        defer { setRefreshing(false, for: accountID) }

        do {
            let result = try await UsageService.fetchUsage(for: account)
            replaceAccountIfNeeded(result.account)
            recordUsageHistorySnapshot(result.usage, for: accountID)
            setUsage(result.usage, for: accountID)
            if announce {
                postMessage("Usage refreshed for \(result.account.name).")
            }
        } catch {
            setUsage(UsageInfo.error(for: accountID, message: error.localizedDescription), for: accountID)
            if announce {
                postMessage(error.localizedDescription, isError: true)
            }
        }
    }

    func refreshAllUsage(announce: Bool = true) async {
        guard !accounts.isEmpty else {
            return
        }

        isRefreshingAll = true
        defer { isRefreshingAll = false }

        for account in accounts {
            await refreshUsage(for: account.id, announce: false)
        }

        if announce {
            postMessage("Usage refreshed for \(accounts.count) account\(accounts.count == 1 ? "" : "s").")
        }
    }

    func startOAuthAddAccount(named rawName: String) {
        let name = rawName.trimmed
        guard validateNewAccountName(name) else { return }

        cancelOAuthAddAccount(silent: true)

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let session = try await OAuthLoginService.startLogin(accountName: name)
                oauthLoginSession = session
                pendingOAuthLogin = PendingOAuthLoginState(
                    accountName: name,
                    authURL: session.authURL,
                    callbackPort: session.callbackPort
                )

                NSWorkspace.shared.open(session.authURL)
                await waitForOAuthAddAccountCompletion(session)
            } catch {
                postMessage(error.localizedDescription, isError: true)
            }
        }
    }

    func reopenOAuthBrowser() {
        guard let authURL = pendingOAuthLogin?.authURL else {
            return
        }
        NSWorkspace.shared.open(authURL)
    }

    func cancelOAuthAddAccount(silent: Bool = false) {
        oauthCompletionTask?.cancel()
        oauthCompletionTask = nil
        oauthLoginSession?.cancel()
        oauthLoginSession = nil
        pendingOAuthLogin = nil

        if !silent {
            flashMessage = nil
        }
    }

    func importCurrentAccount(named rawName: String) -> Bool {
        let name = rawName.trimmed
        guard validateNewAccountName(name) else { return false }

        do {
            let account = try AuthFileService.importCurrentCodexAuth(named: name)
            try insertAccount(account)
            postMessage("Imported current auth.json as \(name).")
            Task {
                await refreshUsage(for: account.id, announce: false)
            }
            return true
        } catch {
            postMessage(error.localizedDescription, isError: true)
            return false
        }
    }

    func importFromOpenPanel(named rawName: String) -> Bool {
        let name = rawName.trimmed
        guard validateNewAccountName(name) else { return false }
        guard let url = chooseAuthFileURL() else { return false }

        do {
            let account = try AuthFileService.importAuthFile(at: url, named: name)
            try insertAccount(account)
            postMessage("Imported \(name) from file.")
            Task {
                await refreshUsage(for: account.id, announce: false)
            }
            return true
        } catch {
            postMessage(error.localizedDescription, isError: true)
            return false
        }
    }

    func importCodexSwitcherFullExport() -> Bool {
        guard let url = chooseCodexSwitcherExportURL() else {
            return false
        }

        do {
            let importedStore = try CodexSwitcherExportService.importFullExport(from: url)
            let summary = try mergeImportedStore(importedStore)

            if let activeAccount {
                try AuthFileService.writeCurrentAuth(for: activeAccount)
            }

            if summary.importedCount > 0 {
                let importedIDs = summary.importedAccountIDs
                Task {
                    for accountID in importedIDs {
                        await refreshUsage(for: accountID, announce: false)
                    }
                }
            }

            let skippedSuffix = summary.skippedCount > 0 ? ", skipped \(summary.skippedCount)" : ""
            postMessage("Imported \(summary.importedCount) account\(summary.importedCount == 1 ? "" : "s") from \(url.lastPathComponent)\(skippedSuffix).")
            return true
        } catch {
            postMessage(error.localizedDescription, isError: true)
            return false
        }
    }

    func importPastedAuthJSON(named rawName: String, json: String) -> Bool {
        let name = rawName.trimmed
        guard validateNewAccountName(name) else { return false }

        let payload = json.trimmed
        guard !payload.isEmpty else {
            postMessage("Paste auth.json content before importing.", isError: true)
            return false
        }

        do {
            let account = try AuthFileService.importAuthJSONString(payload, named: name)
            try insertAccount(account)
            postMessage("Imported pasted auth.json as \(name).")
            Task {
                await refreshUsage(for: account.id, announce: false)
            }
            return true
        } catch {
            postMessage(error.localizedDescription, isError: true)
            return false
        }
    }

    func addAPIKeyAccount(named rawName: String, apiKey rawAPIKey: String) -> Bool {
        _ = rawName
        _ = rawAPIKey
        postMessage("This app only supports ChatGPT subscription accounts.", isError: true)
        return false
    }

    func renameAccount(_ accountID: UUID, to rawName: String) -> Bool {
        let newName = rawName.trimmed
        guard !newName.isEmpty else {
            postMessage("Account name cannot be empty.", isError: true)
            return false
        }

        guard let index = store.accounts.firstIndex(where: { $0.id == accountID }) else {
            postMessage("That account no longer exists.", isError: true)
            return false
        }

        if store.accounts.contains(where: {
            $0.id != accountID && $0.name.caseInsensitiveCompare(newName) == .orderedSame
        }) {
            postMessage("An account named \(newName) already exists.", isError: true)
            return false
        }

        var updatedStore = store
        updatedStore.accounts[index].name = newName

        do {
            store = try persistedStore(from: updatedStore)
            syncSelectionWithStore()
            postMessage("Renamed account to \(newName).")
            return true
        } catch {
            postMessage(error.localizedDescription, isError: true)
            return false
        }
    }

    func deleteAccount(_ accountID: UUID) {
        guard let index = store.accounts.firstIndex(where: { $0.id == accountID }) else {
            return
        }

        var updatedStore = store
        let deleted = updatedStore.accounts.remove(at: index)

        if updatedStore.activeAccountID == accountID {
            updatedStore.activeAccountID = updatedStore.accounts.first?.id
        }

        do {
            let persistedStore = try commitStoreChange(updatedStore, syncActiveAuth: true)
            store = persistedStore
            syncSelectionWithStore(preferActive: true)
            removeUsage(for: accountID)
            removeUsageHistory(for: accountID)
            postMessage("Deleted \(deleted.name).")
        } catch {
            postMessage(error.localizedDescription, isError: true)
        }
    }

    func revealStorageFolder() {
        AppPaths.revealStorageDirectory()
    }

    private func startStartupRefreshIfNeeded() {
        guard !shouldSkipStartupUsageRefresh, !hasStartedStartupRefresh, !accounts.isEmpty else {
            return
        }

        hasStartedStartupRefresh = true
        startupRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startupRefreshTask = nil }
            await self.refreshAllUsage(announce: false)
        }
    }

    private func scheduleInitialMenuLoadingDismissal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumInitialLoadingDelay) { [weak self] in
            self?.isInitialMenuLoadInProgress = false
        }
    }

    private func loadStore() {
        do {
            var loadedStore = try LocalStore.load()
            normalizeStore(&loadedStore)
            store = loadedStore
        } catch {
            store = AccountsStore()
            postMessage("Failed to load saved accounts: \(error.localizedDescription)", isError: true)
        }
    }

    private func loadUsageHistory() {
        do {
            usageHistoryByAccount = try UsageHistoryStore.load()
        } catch {
            usageHistoryByAccount = [:]
        }
    }

    private func waitForOAuthAddAccountCompletion(_ session: OAuthLoginSession) async {
        oauthCompletionTask?.cancel()
        oauthCompletionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let account = try await session.resultTask.value
                guard oauthLoginSession === session else { return }

                try insertAccount(account)
                pendingOAuthLogin = nil
                oauthLoginSession = nil
                await activateAccount(account.id)
                await refreshUsage(for: account.id, announce: false)
            } catch {
                guard oauthLoginSession === session else { return }

                pendingOAuthLogin = nil
                oauthLoginSession = nil

                let message = error.localizedDescription
                if message != "OAuth login cancelled." {
                    postMessage(message, isError: true)
                }
            }
        }
    }

    private func normalizeStore(_ store: inout AccountsStore) {
        if let activeAccountID = store.activeAccountID,
           !store.accounts.contains(where: { $0.id == activeAccountID })
        {
            store.activeAccountID = store.accounts.first?.id
        }
    }

    private func persistedStore(from store: AccountsStore) throws -> AccountsStore {
        var normalizedStore = store
        normalizeStore(&normalizedStore)
        try LocalStore.save(normalizedStore)
        return normalizedStore
    }

    private func mergeImportedStore(_ imported: AccountsStore) throws -> ImportMergeSummary {
        try validateImportedStore(imported)

        let importedActiveID = imported.activeAccountID
        let totalInPayload = imported.accounts.count
        var importedCount = 0
        var importedAccountIDs: [UUID] = []

        var updatedStore = store
        var existingIDs = Set(updatedStore.accounts.map(\.id))
        var existingNames = Set(updatedStore.accounts.map { $0.name.lowercased() })

        for account in imported.accounts {
            let loweredName = account.name.lowercased()
            if existingIDs.contains(account.id) || existingNames.contains(loweredName) {
                continue
            }

            existingIDs.insert(account.id)
            existingNames.insert(loweredName)
            updatedStore.accounts.append(account)
            importedCount += 1
            importedAccountIDs.append(account.id)
        }

        updatedStore.version = max(updatedStore.version, max(imported.version, 1))

        let currentActiveIsValid = updatedStore.activeAccountID.flatMap { activeID in
            updatedStore.accounts.contains(where: { $0.id == activeID }) ? activeID : nil
        } != nil

        if !currentActiveIsValid {
            if let importedActiveID,
               updatedStore.accounts.contains(where: { $0.id == importedActiveID })
            {
                updatedStore.activeAccountID = importedActiveID
            } else {
                updatedStore.activeAccountID = updatedStore.accounts.first?.id
            }
        }

        store = try commitStoreChange(updatedStore, syncActiveAuth: true)
        syncSelectionWithStore()

        return ImportMergeSummary(
            totalInPayload: totalInPayload,
            importedCount: importedCount,
            skippedCount: totalInPayload - importedCount,
            importedAccountIDs: importedAccountIDs
        )
    }

    private func insertAccount(_ account: StoredAccount) throws {
        if store.accounts.contains(where: { $0.name.caseInsensitiveCompare(account.name) == .orderedSame }) {
            throw AppError(message: "An account named \(account.name) already exists.")
        }

        var updatedStore = store
        updatedStore.accounts.append(account)

        if updatedStore.activeAccountID == nil {
            updatedStore.activeAccountID = account.id
        }

        let persistedStore = try commitStoreChange(updatedStore, syncActiveAuth: updatedStore.activeAccountID == account.id)
        store = persistedStore
        syncSelectionWithStore()
    }

    private func replaceAccountIfNeeded(_ updatedAccount: StoredAccount) {
        guard let index = store.accounts.firstIndex(where: { $0.id == updatedAccount.id }) else {
            return
        }

        guard store.accounts[index] != updatedAccount else {
            return
        }

        var updatedStore = store
        updatedStore.accounts[index] = updatedAccount

        do {
            let persistedStore = try commitStoreChange(updatedStore, syncActiveAuth: updatedStore.activeAccountID == updatedAccount.id)
            store = persistedStore
            syncSelectionWithStore()
        } catch {
            postMessage(error.localizedDescription, isError: true)
        }
    }

    private func validateNewAccountName(_ name: String) -> Bool {
        guard !name.isEmpty else {
            postMessage("Give the account a short name first.", isError: true)
            return false
        }

        if store.accounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            postMessage("An account named \(name) already exists.", isError: true)
            return false
        }

        return true
    }

    private func validateImportedStore(_ imported: AccountsStore) throws {
        var ids = Set<UUID>()
        var names = Set<String>()

        for account in imported.accounts {
            let trimmedName = account.name.trimmed
            if trimmedName.isEmpty {
                throw AppError(message: "Import contains an account with an empty name.")
            }

            if !ids.insert(account.id).inserted {
                throw AppError(message: "Import contains duplicate account IDs.")
            }

            if !names.insert(trimmedName.lowercased()).inserted {
                throw AppError(message: "Import contains duplicate account names.")
            }
        }

        if let activeAccountID = imported.activeAccountID,
           !ids.contains(activeAccountID)
        {
            throw AppError(message: "Import references a missing active account.")
        }
    }

    private func commitStoreChange(_ updatedStore: AccountsStore, syncActiveAuth: Bool) throws -> AccountsStore {
        let previousActiveAccount = activeAccount
        let normalizedStore = normalizedStore(from: updatedStore)

        if syncActiveAuth {
            try syncAuthFile(for: normalizedStore)
        }

        do {
            try LocalStore.save(normalizedStore)
            return normalizedStore
        } catch {
            if syncActiveAuth {
                restoreAuthFile(from: previousActiveAccount)
            }
            throw error
        }
    }

    private func normalizedStore(from store: AccountsStore) -> AccountsStore {
        var normalizedStore = store
        normalizeStore(&normalizedStore)
        return normalizedStore
    }

    private func syncActiveAuthFileWithStore() {
        do {
            try syncAuthFile(for: store)
        } catch {
            postMessage("Failed to sync active auth: \(error.localizedDescription)", isError: true)
        }
    }

    private func syncAuthFile(for store: AccountsStore) throws {
        if let activeAccount = activeAccount(in: store) {
            try AuthFileService.writeCurrentAuth(for: activeAccount)
        } else {
            try AuthFileService.clearCurrentAuth()
        }
    }

    private func restoreAuthFile(from account: StoredAccount?) {
        if let account {
            try? AuthFileService.writeCurrentAuth(for: account)
        } else {
            try? AuthFileService.clearCurrentAuth()
        }
    }

    private func activeAccount(in store: AccountsStore) -> StoredAccount? {
        guard let activeAccountID = store.activeAccountID else {
            return nil
        }
        return store.accounts.first(where: { $0.id == activeAccountID })
    }

    private func syncSelectionWithStore(preferActive: Bool = false) {
        if preferActive, let activeAccountID = store.activeAccountID {
            selectedAccountID = activeAccountID
            return
        }

        if let selectedAccountID,
           store.accounts.contains(where: { $0.id == selectedAccountID })
        {
            return
        }

        selectedAccountID = store.activeAccountID ?? store.accounts.first?.id
    }

    private func postMessage(_ text: String, isError: Bool = false) {
        clearMessageTask?.cancel()
        flashMessage = FlashMessage(text: text, isError: isError)

        clearMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            if self.flashMessage?.text == text {
                self.flashMessage = nil
            }
        }
    }

    private func setUsage(_ usage: UsageInfo, for accountID: UUID) {
        var nextUsage = usageByAccount
        nextUsage[accountID] = usage
        usageByAccount = nextUsage
    }

    private func removeUsage(for accountID: UUID) {
        var nextUsage = usageByAccount
        nextUsage.removeValue(forKey: accountID)
        usageByAccount = nextUsage
    }

    private func recordUsageHistorySnapshot(_ usage: UsageInfo, for accountID: UUID) {
        let updatedHistory = UsageHistoryStore.record(
            usage: usage,
            for: accountID,
            historyByAccount: usageHistoryByAccount
        )

        guard updatedHistory != usageHistoryByAccount else {
            return
        }

        usageHistoryByAccount = updatedHistory
        try? UsageHistoryStore.save(updatedHistory)
    }

    private func removeUsageHistory(for accountID: UUID) {
        var nextHistory = usageHistoryByAccount
        nextHistory.removeValue(forKey: accountID)
        usageHistoryByAccount = nextHistory
        try? UsageHistoryStore.save(nextHistory)
    }

    private func setRefreshing(_ isRefreshing: Bool, for accountID: UUID) {
        var nextRefreshing = refreshingAccountIDs
        if isRefreshing {
            nextRefreshing.insert(accountID)
        } else {
            nextRefreshing.remove(accountID)
        }
        refreshingAccountIDs = nextRefreshing
    }
}

private struct ImportMergeSummary {
    var totalInPayload: Int
    var importedCount: Int
    var skippedCount: Int
    var importedAccountIDs: [UUID]
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
