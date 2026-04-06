import AppKit
import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.menuBarSymbolName)
                .symbolRenderingMode(.hierarchical)

            if let label = model.menuBarLabelText, !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
    }
}

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let flashMessage = model.flashMessage {
                FlashMessageView(message: flashMessage)
            }

            if model.accounts.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Accounts")
                        .font(.headline)

                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(model.accounts) { account in
                                AccountSwitchRow(account: account)
                            }
                        }
                        .padding(.top, 1)
                        .animation(.snappy(duration: 0.2), value: model.activeAccount?.id)
                    }
                    .frame(minHeight: menuAccountListMinHeight, maxHeight: 420)
                }

                footerActions
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .task {
            await model.refreshProcessStatus()
        }
    }

    private var menuAccountListMinHeight: CGFloat {
        CGFloat(min(max(model.accounts.count, 1), 3)) * 118
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex Switcher")
                    .font(.title3.weight(.semibold))

                if model.processStatus.hasRunningCodex {
                    Label("Codex is running", systemImage: "bolt.horizontal.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if model.activeAccount == nil {
                    Text("No account selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Menu bar edition")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task {
                    await model.refreshAllUsage()
                }
            } label: {
                if model.isRefreshingAll {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import your first account to get started.")
                .font(.body)

            Button("Manage Accounts") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "accounts")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var footerActions: some View {
        HStack {
            Button("Manage Accounts") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "accounts")
            }

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
    }
}

struct AccountSwitchRow: View {
    let account: StoredAccount

    @EnvironmentObject private var model: AppModel

    var body: some View {
        let isActive = model.isActive(account.id)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.name)
                    .font(.body.weight(.medium))

                if let email = account.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: isActive)
                }

                Spacer(minLength: 8)

                if model.isRefreshing(account.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task {
                            await model.refreshUsage(for: account.id)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh usage")
                }

                Button(isActive ? "Active" : "Switch") {
                    Task {
                        await model.activateAccount(account.id)
                    }
                }
                .applySwitcherButtonStyle(isProminent: !isActive)
                .controlSize(.small)
                .disabled(model.switchingAccountID == account.id)
            }

            CompactUsageStack(usage: model.usageInfo(for: account.id), authMode: account.authMode)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.28) : .clear, lineWidth: 1)
        )
        .shadow(color: isActive ? Color.accentColor.opacity(0.10) : .clear, radius: 10, y: 4)
        .animation(.snappy(duration: 0.2), value: isActive)
    }
}

struct AccountsManagementView: View {
    @EnvironmentObject private var model: AppModel

    @State private var newAccountName = ""
    @State private var apiKey = ""
    @State private var pastedAuthJSON = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accounts")
                            .font(.largeTitle.weight(.bold))
                        Text("Add, rename, refresh, and switch stored Codex accounts.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Reveal Storage") {
                        model.revealStorageFolder()
                    }

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
                                description: Text("Import a `.cswf` export, import an auth.json file, or add an API key account.")
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
                    Text("From Original Codex Switcher")
                        .font(.subheadline.weight(.semibold))

                    Button("Import .cswf Export…") {
                        _ = model.importCodexSwitcherFullExport()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Imports the encrypted full export created by the original desktop app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                TextField("Account name", text: $newAccountName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Import Current auth.json") {
                        if model.importCurrentAccount(named: newAccountName) {
                            clearDrafts(keepAPIKey: true, keepAuthJSON: true)
                        }
                    }

                    Button("Choose auth.json File…") {
                        if model.importFromOpenPanel(named: newAccountName) {
                            clearDrafts(keepAPIKey: true, keepAuthJSON: true)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick API Key")
                        .font(.subheadline.weight(.semibold))

                    HStack {
                        SecureField("OpenAI API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        Button("Add API Key Account") {
                            if model.addAPIKeyAccount(named: newAccountName, apiKey: apiKey) {
                                clearDrafts(keepAPIKey: false, keepAuthJSON: true)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                DisclosureGroup("Paste auth.json manually") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: $pastedAuthJSON)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 160)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )

                        HStack {
                            Spacer()

                            Button("Import Pasted auth.json") {
                                if model.importPastedAuthJSON(named: newAccountName, json: pastedAuthJSON) {
                                    clearDrafts(keepAPIKey: true, keepAuthJSON: false)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(8)
        }
    }

    private func clearDrafts(keepAPIKey: Bool, keepAuthJSON: Bool) {
        newAccountName = ""
        if !keepAPIKey {
            apiKey = ""
        }
        if !keepAuthJSON {
            pastedAuthJSON = ""
        }
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
                        if let email = account.email, !email.isEmpty {
                            Text(email)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(account.subtitle)
                                .foregroundStyle(.secondary)
                        }

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
                    if let primaryPercent = usage.primaryUsedPercent {
                        UsageMetricRow(
                            title: usage.primaryWindowMinutes == 300 ? "5-hour window" : "Primary window",
                            percent: primaryPercent,
                            fraction: usage.primaryFraction,
                            resetAt: usage.primaryResetsAt
                        )
                    }

                    if let secondaryPercent = usage.secondaryUsedPercent {
                        UsageMetricRow(
                            title: usage.secondaryWindowMinutes == 10080 ? "Weekly window" : "Secondary window",
                            percent: secondaryPercent,
                            fraction: usage.secondaryFraction,
                            resetAt: usage.secondaryResetsAt
                        )
                    }
                }
            } else {
                Label("No usage fetched yet", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct UsageMetricRow: View {
    let title: String
    let percent: Double
    let fraction: Double?
    let resetAt: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metricTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ProgressView(value: fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(percent > 85 ? .orange : .blue)

                Text("\(Int(percent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metricTitle: String {
        if let resetAt {
            return "\(title) · resets \(RelativeTimeFormatter.string(fromUnix: resetAt))"
        }
        return title
    }
}

struct CompactUsageStack: View {
    let usage: UsageInfo?
    let authMode: AuthMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let usage, usage.error == nil {
                if let primary = usage.primaryUsedPercent {
                    UsageMetricRow(
                        title: usage.primaryWindowMinutes == 300 ? "5-hour window" : "Primary window",
                        percent: primary,
                        fraction: usage.primaryFraction,
                        resetAt: usage.primaryResetsAt
                    )
                } else {
                    UsagePlaceholderRow(text: "5-hour window")
                }

                if let secondary = usage.secondaryUsedPercent {
                    UsageMetricRow(
                        title: usage.secondaryWindowMinutes == 10080 ? "Weekly window" : "Secondary window",
                        percent: secondary,
                        fraction: usage.secondaryFraction,
                        resetAt: usage.secondaryResetsAt
                    )
                } else {
                    UsagePlaceholderRow(text: "Weekly window")
                }
            } else if let usage, let error = usage.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(authMode == .apiKey ? "Usage is unavailable for API key accounts." : "Usage not loaded yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct UsagePlaceholderRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                    .tint(.secondary.opacity(0.35))

                Text("—")
                    .font(.caption.monospacedDigit())
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
