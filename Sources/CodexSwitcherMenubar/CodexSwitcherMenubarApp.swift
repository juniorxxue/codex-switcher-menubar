import AppKit

@MainActor
@main
enum CodexSwitcherMenubarMain {
    private static let delegate = AppDelegate()

    static func main() {
        DebugLogger.startSession()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLogger.info("app", "Application did finish launching.")
        let model = AppModel.shared

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL)
        {
            NSApp.applicationIconImage = icon
        } else {
            NSApp.applicationIconImage = AppIcon.makeApplicationIcon()
        }

        AppUIController.shared.configure(with: model)
        model.start()
    }
}
