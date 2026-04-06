import AppKit
import SwiftUI

@main
struct CodexSwitcherMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
                .frame(width: 380)
                .frame(minHeight: 560)
        } label: {
            MenuBarLabelView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Window("Accounts", id: "accounts") {
            AccountsManagementView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 560)
        }
        .defaultSize(width: 720, height: 620)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
