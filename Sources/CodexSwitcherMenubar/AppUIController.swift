import AppKit
import Combine
import SwiftUI

@MainActor
final class AppUIController: NSObject {
    static let shared = AppUIController()

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

        if accountsWindowController?.window?.isVisible == true {
            accountsHostingController?.rootView = makeAccountsManagementRootView(for: model)
        }
    }

    private func updateStatusItemAppearance() {
        guard let model, let button = statusItem?.button else { return }

        if let image = NSImage(systemSymbolName: model.menuBarSymbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            button.image = image
        } else {
            button.image = nil
        }

        let title = model.menuBarLabelText ?? ""
        if title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        } else {
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                ]
            )
            button.imagePosition = .imageLeading
        }
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
        popover.contentSize = NSSize(width: 380, height: 460)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        focusPopoverWindow()
    }

    private func makeMenuBarRootView(for model: AppModel) -> AnyView {
        AnyView(
            MenuBarContentView()
                .environmentObject(model)
                .frame(width: 380)
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
        }
    }
}
