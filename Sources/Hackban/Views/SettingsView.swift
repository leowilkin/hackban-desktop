import AppKit
import HackbanKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings().tabItem { Label("Accounts", systemImage: "person.2") }
            QuickAddSettings().tabItem { Label("Quick Add", systemImage: "plus.rectangle.on.rectangle") }
        }
        .frame(width: 560, height: 440)
    }
}

private struct GeneralSettings: View {
    @AppStorage("hackban:theme") private var theme = "system"
    @AppStorage("hackban:notify") private var notify = true
    @AppStorage("hackban:menuBarExtra") private var menuBar = true
    @AppStorage("hackban:defaultDueHour") private var dueHour = 12
    @AppStorage(Updater.automaticKey) private var autoUpdate = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var updater: Updater { .shared }

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Toggle("Show notifications for new Hackban notifications", isOn: $notify)
            Toggle("Show in menu bar", isOn: $menuBar)
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            Picker("Default time for new due dates", selection: $dueHour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened)).tag(h)
                }
            }
            Section {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                LabeledContent("Hackban \(updater.versionDescription)") {
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }.disabled(updater.busy)
                }
            } header: {
                Text("Updates")
            } footer: {
                if updater.build == 0 {
                    Text("This is a local build, so it only checks when you ask.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirm: ConfirmAction?

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(app.accounts) { a in AccountRow(account: a, confirm: $confirm) }
                    .onMove { from, to in
                        app.accounts.move(fromOffsets: from, toOffset: to)
                        app.save()
                    }
            }
            HStack {
                Button("Add Server…") { app.addingAccount = true }
                Spacer()
                Text("Drag to reorder. Hidden accounts stay signed in but don't show in the sidebar, Home or quick add.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .bottom])
        }
        .confirm($confirm)
        .sheet(isPresented: Binding(get: { app.addingAccount }, set: { app.addingAccount = $0 })) { AddAccountView().environment(app) }
    }
}

private struct AccountRow: View {
    @Bindable var account: Account
    @Binding var confirm: ConfirmAction?
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(AccountPalette.colors.indices, id: \.self) { i in
                    Button { account.config.colorIndex = i; app.save() } label: {
                        Label("Colour \(i + 1)", systemImage: "circle.fill")
                    }
                    .tint(AccountPalette.color(i))
                }
            } label: { Circle().fill(account.color).frame(width: 14, height: 14) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            AvatarView(user: account.profile?.asUser, account: account, size: 28)
            VStack(alignment: .leading) {
                TextField("Name", text: $account.config.label).textFieldStyle(.plain).font(.headline)
                    .onSubmit { app.save() }
                Text("\(account.profile?.email ?? "") · \(account.host)").font(.caption).foregroundStyle(.secondary)
                if account.signedOut { Text("Signed out").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Toggle("Hidden", isOn: Binding(get: { account.config.hidden }, set: { account.config.hidden = $0; app.save() }))
                .toggleStyle(.checkbox)
            if account.signedOut {
                Button("Sign In") { Task { await app.reauthenticate(account) } }
            } else {
                Button("Sign Out") { Task { await app.signOut(account) } }
            }
            Button(role: .destructive) {
                confirm = ConfirmAction(title: "Remove \(account.config.label)?", message: "Hackban for Mac signs out of \(account.host) and forgets it. Nothing on the server changes.", button: "Remove") {
                    Task { await app.remove(account) }
                }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

private struct QuickAddSettings: View {
    @Environment(AppModel.self) private var app
    @State private var shortcut: Shortcut?
    @State private var loaded = false
    @AppStorage("hackban:quickadd:parse") private var parse = true
    @AppStorage("hackban:quickadd:default") private var defaultDestination = ""

    var body: some View {
        Form {
            LabeledContent("Global shortcut") {
                HStack {
                    ShortcutRecorder(shortcut: $shortcut).frame(width: 160, height: 24)
                    Button("Reset") { shortcut = .default }
                    Button("Clear") { shortcut = nil }
                }
            }
            if HotKeyCenter.shared.registrationFailed {
                Text("That shortcut is taken by another app. Pick a different one.").foregroundStyle(.red).font(.caption)
            }
            Text("Opens quick add from anywhere, even when Hackban is in the background. Inside the app, ⇧⌘N works too.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Understand #board, /list, @member, !label and dates", isOn: $parse)
            Picker("Add cards to", selection: $defaultDestination) {
                Text("The last board I used").tag("")
                ForEach(app.visibleAccounts) { a in
                    Section(a.config.label) {
                        ForEach(a.allBoards, id: \.board.id) { item in
                            Text("\(item.board.name) (\(item.workspace))").tag("\(a.id)|\(item.board.id)")
                        }
                    }
                }
            }
            QuickAddHelp()
        }
        .formStyle(.grouped)
        .onAppear { shortcut = HotKeyCenter.shared.shortcut; loaded = true }
        .onChange(of: shortcut) { _, s in if loaded { HotKeyCenter.shared.set(s) } }
    }
}

/// The menu bar extra: quick add, what's due soon, unread notifications.
struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let soon = app.visibleAccounts.flatMap { a in a.myCards.filter { c in
            guard let d = c.due, !c.dueComplete else { return false }
            return d < Date().addingTimeInterval(3 * 86_400)
        }.map { (a, $0) } }
            .sorted { ($0.1.due ?? .distantFuture) < ($1.1.due ?? .distantFuture) }
        VStack(alignment: .leading, spacing: 10) {
            Button {
                QuickAddController.shared.show()
            } label: {
                Label("Quick add a card", systemImage: "plus.rectangle.on.rectangle").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(.hackClubRed)
            Text("Due soon").font(.caption.bold()).foregroundStyle(.secondary)
            if soon.isEmpty { Text("Nothing due in the next 3 days.").font(.callout).foregroundStyle(.secondary) }
            ForEach(soon.prefix(8), id: \.1.id) { pair in
                let a = pair.0, c = pair.1
                Button {
                    show()
                    app.open(card: c.id, in: a, board: c.list?.board?.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(c.title).lineLimit(1)
                            Text(c.list?.board?.name ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        DueBadge(card: c)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            Button {
                show()
                app.route = .notifications
            } label: {
                HStack { Text("Notifications"); Spacer(); if app.totalUnread > 0 { Text("\(app.totalUnread) unread").foregroundStyle(.secondary) } }
            }
            .buttonStyle(.plain)
            Button("Open Hackban") { show() }.buttonStyle(.plain)
            if let release = Updater.shared.available, let n = release.build {
                Button("Update to Build \(n)") { Task { await Updater.shared.install(release) } }
                    .buttonStyle(.plain)
                    .disabled(Updater.shared.busy)
            }
            Divider()
            Button("Quit Hackban") { NSApp.terminate(nil) }.buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 320)
        .task {
            for a in app.visibleAccounts { await a.refreshMyCards() }
        }
    }

    private func show() {
        NSApp.activate()
        // Since macOS 14 activating is only a request, and the menu bar panel doesn't make us the active app, so
        // bring the window up ourselves too. Taking key also closes the panel.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            openWindow(id: "main")
        }
    }
}
