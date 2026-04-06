import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isInitialMenuLoadInProgress {
                InitialMenuLoadingView(accountCount: model.accounts.count)
            } else if model.accounts.isEmpty {
                EmptyMenuBarStateView()
                    .environmentObject(model)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Codex Usage")
                        .font(.headline)

                    AccountTabStrip(accounts: model.accounts)

                    if let selectedAccount = model.selectedAccount {
                        SelectedAccountHeader(account: selectedAccount)
                        SelectedAccountUsageView(account: selectedAccount)

                        Divider()

                        UsageHistoryChartView(points: model.usageHistoryByAccount[selectedAccount.id] ?? [])

                        if let flashMessage = model.flashMessage {
                            Divider()
                            FlashMessageView(message: flashMessage)
                        }

                        Divider()

                        FooterActionBar(account: selectedAccount)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.regularMaterial)
    }
}

struct InitialMenuLoadingView: View {
    let accountCount: Int

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .scaleEffect(0.9)

            Text("Loading accounts...")
                .font(.system(size: 13, weight: .semibold))

            Text(loadingSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 332)
        .frame(minHeight: 160)
    }

    private var loadingSubtitle: String {
        if accountCount > 0 {
            return "Preparing \(accountCount) account\(accountCount == 1 ? "" : "s") and refreshing usage."
        }
        return "Preparing your menu bar workspace."
    }
}

struct EmptyMenuBarStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex Usage")
                .font(.headline)

            Text("Add your first account to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Add Account") {
                AppUIController.shared.showAccountsWindow()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(width: 332, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct AccountTabStrip: View {
    let accounts: [StoredAccount]

    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            segmentedPicker
                .fixedSize(horizontal: true, vertical: false)

            ScrollView(.horizontal, showsIndicators: false) {
                segmentedPicker
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.vertical, 1)
            }
        }
    }

    private var segmentedPicker: some View {
        Picker("Account", selection: selectedAccountID) {
            ForEach(accounts) { account in
                accountSegmentLabel(for: account)
                    .tag(account.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var selectedAccountID: Binding<UUID> {
        let fallbackID = accounts.first?.id ?? UUID()

        return Binding(
            get: { model.selectedAccount?.id ?? fallbackID },
            set: { model.selectAccount($0) }
        )
    }

    @ViewBuilder
    private func accountSegmentLabel(for account: StoredAccount) -> some View {
        if model.isActive(account.id) {
            Label {
                Text(account.name)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Text(account.name)
                .lineLimit(1)
        }
    }
}

struct SelectedAccountHeader: View {
    let account: StoredAccount

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(account.name)
                        .font(.title3.weight(.semibold))

                    if let planBadge = account.planBadge {
                        PlanBadge(text: planBadge)
                    }
                }

                Text(account.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if model.isActive(account.id) {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button("Activate") {
                    Task {
                        await model.activateAccount(account.id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.switchingAccountID == account.id)
            }
        }
    }
}

struct SelectedAccountUsageView: View {
    let account: StoredAccount

    @EnvironmentObject private var model: AppModel

    var body: some View {
        let usage = model.usageInfo(for: account.id)

        VStack(alignment: .leading, spacing: 10) {
            if account.authMode == .apiKey {
                Label("This account needs to be re-added with ChatGPT sign-in.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                UsageBucketPanelRow(
                    label: "5-Hour Window",
                    percent: usage?.error == nil ? usage?.primaryUsedPercent : nil,
                    resetAt: usage?.primaryResetsAt
                )

                UsageBucketPanelRow(
                    label: "7-Day Window",
                    percent: usage?.error == nil ? usage?.secondaryUsedPercent : nil,
                    resetAt: usage?.secondaryResetsAt
                )

                if let error = usage?.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

struct UsageBucketPanelRow: View {
    let label: String
    let percent: Double?
    let resetAt: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)

                Spacer()

                Text(percentText)
                    .font(.subheadline)
                    .monospacedDigit()
            }

            ProgressView(value: progressFraction, total: 1.0)
                .tint(colorForUsageFraction(progressFraction))

            if let resetAt {
                Text("Resets \(RelativeTimeFormatter.string(fromUnix: resetAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var percentText: String {
        guard let percent else {
            return "—"
        }
        return "\(Int(round(percent)))%"
    }

    private var progressFraction: Double {
        guard let percent else {
            return 0
        }
        return min(max(percent / 100, 0), 1)
    }
}

struct FooterActionBar: View {
    let account: StoredAccount

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let usage = model.usageInfo(for: account.id) {
                Text("Updated \(usage.lastUpdatedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            FooterIconButton(systemImage: "gearshape", helpText: "Manage Accounts") {
                AppUIController.shared.showAccountsWindow()
            }

            FooterIconButton(
                systemImage: model.isRefreshingAll ? "arrow.clockwise.circle.fill" : "arrow.clockwise",
                helpText: "Refresh"
            ) {
                Task {
                    await model.refreshAllUsage()
                }
            }
            .disabled(model.accounts.isEmpty || model.isRefreshingAll)

            FooterIconButton(systemImage: "power", helpText: "Quit") {
                NSApp.terminate(nil)
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct FooterIconButton: View {
    let systemImage: String
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

struct AccountsManagementView: View {
    @EnvironmentObject private var model: AppModel

    @State private var newAccountName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button("Reveal Storage") {
                        model.revealStorageFolder()
                    }

                    Spacer()

                    Button("Refresh All Usage") {
                        Task {
                            await model.refreshAllUsage()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let flashMessage = model.flashMessage {
                    FlashMessageView(message: flashMessage)
                }

                addAccountSection

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Stored Accounts")
                                .font(.headline)
                            Spacer()
                            if model.processStatus.hasRunningCodex {
                                Label("Codex running", systemImage: "bolt.horizontal.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        if model.accounts.isEmpty {
                            ContentUnavailableView(
                                "No Accounts Yet",
                                systemImage: "person.crop.circle.badge.plus",
                                description: Text("Add a ChatGPT account, or import an existing `.cswf` export or `auth.json`.")
                            )
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(model.accounts) { account in
                                    ManagedAccountRow(account: account)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
    }

    private var addAccountSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Account")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a ChatGPT subscription account with the official OAuth flow.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("Account name", text: $newAccountName)
                        .textFieldStyle(.roundedBorder)

                    Button("Add Account with ChatGPT") {
                        model.startOAuthAddAccount(named: newAccountName)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pendingOAuthLogin != nil)
                }

                if let pendingOAuthLogin = model.pendingOAuthLogin {
                    OAuthPendingCard(pendingOAuthLogin: pendingOAuthLogin)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Migrate Existing Accounts")
                        .font(.subheadline.weight(.semibold))

                    Text("Import is still available for accounts you already added elsewhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Import .cswf Export…") {
                        _ = model.importCodexSwitcherFullExport()
                    }
                    .buttonStyle(.bordered)

                    HStack {
                        Button("Import Current auth.json") {
                            if model.importCurrentAccount(named: newAccountName) {
                                clearDrafts()
                            }
                        }

                        Button("Choose auth.json File…") {
                            if model.importFromOpenPanel(named: newAccountName) {
                                clearDrafts()
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func clearDrafts() {
        newAccountName = ""
    }
}

struct OAuthPendingCard: View {
    let pendingOAuthLogin: PendingOAuthLoginState

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Waiting for browser sign-in", systemImage: "globe")
                .font(.subheadline.weight(.semibold))

            Text("A ChatGPT login window was opened for `\(pendingOAuthLogin.accountName)`. Finish the login there and this account will be added automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Open Browser Again") {
                    model.reopenOAuthBrowser()
                }
                .buttonStyle(.bordered)

                Button("Cancel") {
                    model.cancelOAuthAddAccount()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct ManagedAccountRow: View {
    let account: StoredAccount

    @EnvironmentObject private var model: AppModel
    @State private var draftName: String

    init(account: StoredAccount) {
        self.account = account
        _draftName = State(initialValue: account.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: account.authMode == .chatGPT ? "bolt.circle.fill" : "key.fill")
                            .foregroundStyle(account.authMode == .chatGPT ? .blue : .secondary)

                        TextField("Name", text: $draftName)
                            .textFieldStyle(.roundedBorder)

                        if draftName != account.name {
                            Button("Save") {
                                if model.renameAccount(account.id, to: draftName) {
                                    draftName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Text(account.subtitle)
                            .foregroundStyle(.secondary)

                        if let planBadge = account.planBadge {
                            PlanBadge(text: planBadge)
                        }

                        if model.isActive(account.id) {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.subheadline)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        Task {
                            await model.refreshUsage(for: account.id)
                        }
                    } label: {
                        if model.isRefreshing(account.id) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)

                    Button(model.isActive(account.id) ? "Active" : "Activate") {
                        Task {
                            await model.activateAccount(account.id)
                        }
                    }
                    .applySwitcherButtonStyle(isProminent: !model.isActive(account.id))

                    Button(role: .destructive) {
                        model.deleteAccount(account.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }

            UsageSummaryView(usage: model.usageInfo(for: account.id))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct UsageSummaryView: View {
    let usage: UsageInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let usage {
                if let error = usage.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    UsageBucketPanelRow(
                        label: usage.primaryWindowMinutes == 300 ? "5-Hour Window" : "Primary Window",
                        percent: usage.primaryUsedPercent,
                        resetAt: usage.primaryResetsAt
                    )

                    UsageBucketPanelRow(
                        label: usage.secondaryWindowMinutes == 10080 ? "7-Day Window" : "Secondary Window",
                        percent: usage.secondaryUsedPercent,
                        resetAt: usage.secondaryResetsAt
                    )
                }
            } else {
                Label("No usage fetched yet", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .foregroundStyle(Color.accentColor)
    }
}

struct FlashMessageView: View {
    let message: FlashMessage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(message.isError ? .orange : .green)

            Text(message.text)
                .font(.caption)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

enum RelativeTimeFormatter {
    static func string(fromUnix value: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let targetDate = Date(timeIntervalSince1970: TimeInterval(value))
        return formatter.localizedString(for: targetDate, relativeTo: Date())
    }
}

private struct SwitcherButtonStyleModifier: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private extension View {
    func applySwitcherButtonStyle(isProminent: Bool) -> some View {
        modifier(SwitcherButtonStyleModifier(isProminent: isProminent))
    }
}

private func colorForUsageFraction(_ fraction: Double) -> Color {
    switch fraction {
    case ..<0.60:
        return .green
    case 0.60..<0.80:
        return .yellow
    default:
        return .red
    }
}
