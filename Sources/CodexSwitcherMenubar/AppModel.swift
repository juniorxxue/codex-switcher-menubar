import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var store = AccountsStore()
    @Published private(set) var usageByAccount: [UUID: UsageInfo] = [:]
    @Published private(set) var refreshingAccountIDs: Set<UUID> = []
    @Published private(set) var processStatus = CodexProcessStatus()
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var switchingAccountID: UUID?
    @Published var flashMessage: FlashMessage?

    private var clearMessageTask: Task<Void, Never>?

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
        Task {
            await bootstrap()
        }
    }

    deinit {
        clearMessageTask?.cancel()
    }

    func usageInfo(for accountID: UUID) -> UsageInfo? {
        usageByAccount[accountID]
    }

    func isRefreshing(_ accountID: UUID) -> Bool {
        refreshingAccountIDs.contains(accountID)
    }

    func isActive(_ accountID: UUID) -> Bool {
        store.activeAccountID == accountID
    }

    func refreshProcessStatus() async {
        let status = await Task.detached(priority: .utility) {
            CodexProcessService.runningCodexStatus()
        }.value
        processStatus = status
    }

    func activateAccount(_ accountID: UUID) async {
        guard let accountIndex = store.accounts.firstIndex(where: { $0.id == accountID }) else {
            postMessage("That account no longer exists.", isError: true)
            return
        }

        switchingAccountID = accountID
        defer { switchingAccountID = nil }

        await refreshProcessStatus()

        var updatedStore = store
        updatedStore.activeAccountID = accountID
        updatedStore.accounts[accountIndex].lastUsedAt = Date()

        do {
            let persistedStore = try persistedStore(from: updatedStore)
            guard let activeIndex = persistedStore.accounts.firstIndex(where: { $0.id == accountID }) else {
                throw AppError(message: "Switched account could not be found after saving.")
            }

            try AuthFileService.writeCurrentAuth(for: persistedStore.accounts[activeIndex])
            store = persistedStore

            if processStatus.hasRunningCodex {
                postMessage("Switched while Codex is running. New shells will use the new account.")
            } else {
                postMessage("Switched to \(persistedStore.accounts[activeIndex].name).")
            }
        } catch {
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

    func refreshAllUsage() async {
        guard !accounts.isEmpty else {
            return
        }

        isRefreshingAll = true
        defer { isRefreshingAll = false }

        for account in accounts {
            await refreshUsage(for: account.id, announce: false)
        }

        postMessage("Usage refreshed for \(accounts.count) account\(accounts.count == 1 ? "" : "s").")
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
        let name = rawName.trimmed
        guard validateNewAccountName(name) else { return false }

        let apiKey = rawAPIKey.trimmed
        guard !apiKey.isEmpty else {
            postMessage("Add an API key before creating the account.", isError: true)
            return false
        }

        do {
            try insertAccount(.makeAPIKey(name: name, apiKey: apiKey))
            postMessage("Added API key account \(name).")
            return true
        } catch {
            postMessage(error.localizedDescription, isError: true)
            return false
        }
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
            let persistedStore = try persistedStore(from: updatedStore)

            if let activeAccountID = persistedStore.activeAccountID,
               let activeAccount = persistedStore.accounts.first(where: { $0.id == activeAccountID })
            {
                try AuthFileService.writeCurrentAuth(for: activeAccount)
            } else {
                try AuthFileService.clearCurrentAuth()
            }

            store = persistedStore
            removeUsage(for: accountID)
            postMessage("Deleted \(deleted.name).")
        } catch {
            postMessage(error.localizedDescription, isError: true)
        }
    }

    func revealStorageFolder() {
        AppPaths.revealStorageDirectory()
    }

    private func bootstrap() async {
        await refreshProcessStatus()
        if !accounts.isEmpty {
            await refreshAllUsage()
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

        store = try persistedStore(from: updatedStore)

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

        let persistedStore = try persistedStore(from: updatedStore)

        if persistedStore.activeAccountID == account.id {
            try AuthFileService.writeCurrentAuth(for: account)
        }

        store = persistedStore
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
            let persistedStore = try persistedStore(from: updatedStore)
            if persistedStore.activeAccountID == updatedAccount.id {
                try AuthFileService.writeCurrentAuth(for: updatedAccount)
            }
            store = persistedStore
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
