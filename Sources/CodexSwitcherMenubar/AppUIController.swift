import AppKit
import Combine
import SwiftUI

@MainActor
final class AppUIController: NSObject {
    static let shared = AppUIController()

    private let popoverWidth: CGFloat = 356
    private let minimumPopoverHeight: CGFloat = 190
    private let maximumPopoverHeight: CGFloat = 520
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var accountsWindowController: NSWindowController?
    private var popoverHostingController: NSHostingController<AnyView>?
    private var accountsHostingController: NSHostingController<AnyView>?
    private var cancellables: Set<AnyCancellable> = []

    func configure(with model: AppModel) {
        guard self.model == nil else {
            updateStatusItemAppearance()
            return
        }

        self.model = model
        setupPopover()
        setupStatusItem()
        observeModel()
        updateStatusItemAppearance()
    }

    func showAccountsWindow() {
        guard let model else { return }

        if accountsWindowController == nil {
            let hostingController = NSHostingController(rootView: makeAccountsManagementRootView(for: model))
            accountsHostingController = hostingController
            let window = NSWindow(contentViewController: hostingController)
            window.setContentSize(NSSize(width: 720, height: 620))
            window.minSize = NSSize(width: 680, height: 560)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            accountsWindowController = NSWindowController(window: window)
        } else if let accountsHostingController {
            accountsHostingController.rootView = makeAccountsManagementRootView(for: model)
        }

        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        accountsWindowController?.showWindow(nil)
        accountsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func closePopover() {
        popover.performClose(nil)
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true

        guard let model else { return }
        let hostingController = NSHostingController(rootView: makeMenuBarRootView(for: model))
        popoverHostingController = hostingController
        popover.contentViewController = hostingController
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func observeModel() {
        guard let model else { return }

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemAppearance()
                    self?.refreshVisibleContent()
                }
            }
            .store(in: &cancellables)
    }

    private func refreshVisibleContent() {
        guard let model else { return }

        popoverHostingController?.rootView = makeMenuBarRootView(for: model)
        resizePopoverToFitContent()

        if accountsWindowController?.window?.isVisible == true {
            accountsHostingController?.rootView = makeAccountsManagementRootView(for: model)
        }
    }

    private func updateStatusItemAppearance() {
        guard let model, let button = statusItem?.button else { return }

        let activeUsage = model.activeAccount.flatMap { model.usageInfo(for: $0.id) }
        button.image = renderUsageMenuBarIcon(
            primaryFraction: activeUsage?.error == nil ? activeUsage?.primaryFraction : nil,
            secondaryFraction: activeUsage?.error == nil ? activeUsage?.secondaryFraction : nil
        )
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        button.toolTip = model.activeAccount?.name ?? "Codex Switcher Menubar"
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            closePopover()
            return
        }

        if let popoverHostingController, let model {
            popoverHostingController.rootView = makeMenuBarRootView(for: model)
        }

        NSApp.activate(ignoringOtherApps: true)
        resizePopoverToFitContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        focusPopoverWindow()
    }

    private func makeMenuBarRootView(for model: AppModel) -> AnyView {
        AnyView(
            MenuBarContentView()
                .environmentObject(model)
                .frame(width: popoverWidth)
        )
    }

    private func makeAccountsManagementRootView(for model: AppModel) -> AnyView {
        AnyView(
            AccountsManagementView()
                .environmentObject(model)
        )
    }

    private func focusPopoverWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.popover.contentViewController?.view.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            window.makeFirstResponder(window.contentView)
            self?.resizePopoverToFitContent()
        }
    }

    private func resizePopoverToFitContent() {
        guard let view = popoverHostingController?.view else {
            return
        }

        view.layoutSubtreeIfNeeded()
        let fittingSize = view.fittingSize
        let targetHeight = min(max(fittingSize.height, minimumPopoverHeight), maximumPopoverHeight)
        popover.contentSize = NSSize(width: popoverWidth, height: targetHeight)
    }
}
