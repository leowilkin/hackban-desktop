import AppKit
import HackbanKit
import SwiftUI
import UserNotifications

@main
struct HackbanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared
    @AppStorage("hackban:theme") private var theme = "system"
    @AppStorage("hackban:menuBarExtra") private var showMenuBar = true

    var body: some Scene {
        WindowGroup("Hackban", id: "main") {
            MainView()
                .environment(app)
                .preferredColorScheme(colorScheme)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands { HackbanCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
                .preferredColorScheme(colorScheme)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView().environment(app)
        } label: {
            Image(systemName: app.totalUnread > 0 ? "rectangle.split.3x1.fill" : "rectangle.split.3x1")
        }
        .menuBarExtraStyle(.window)
    }

    private var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct HackbanCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Quick Add Card…") { QuickAddController.shared.show() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Go to Board…") { app.showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Join Board from Link…") { JoinLinkPanel.present(app: app) }
            Divider()
            Button("Refresh") { Task { await app.refreshAll() } }
                .keyboardShortcut("r", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Home") { app.route = .home }.keyboardShortcut("1", modifiers: .command)
            Button("My Cards") { app.route = .myCards }.keyboardShortcut("2", modifiers: .command)
            Button("Notifications") { app.route = .notifications }.keyboardShortcut("3", modifiers: .command)
            Button("Search") { app.route = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        // `swift run` starts us as a background process; make sure we get a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated {
            HotKeyCenter.shared.registerSavedShortcut()
            AppModel.shared.start()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            Task { await AppModel.shared.pollNotifications() }
        }
    }

    /// Clicking a notification opens its card.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let accountId = info["account"] as? String, let card = info["card"] as? String, !card.isEmpty else { return }
        let board = info["board"] as? String
        let nid = info["notification"] as? String
        await MainActor.run {
            let app = AppModel.shared
            guard let a = app.account(accountId) else { return }
            NSApp.activate(ignoringOtherApps: true)
            app.open(card: card, in: a, board: board?.isEmpty == false ? board : nil)
            if let nid, let n = a.notifications.first(where: { $0.id == nid }) { app.markRead(n, in: a) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
