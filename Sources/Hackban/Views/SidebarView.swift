import HackbanKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var creatingBoard: Account?
    @State private var creatingWorkspace: Account?

    var body: some View {
        @Bindable var app = app
        List(selection: $app.route) {
            Section {
                Label("Home", systemImage: "house").tag(Route.home)
                Label("My Cards", systemImage: "person.crop.rectangle.stack").tag(Route.myCards)
                Label("Notifications", systemImage: "bell")
                    .badge(app.totalUnread)
                    .tag(Route.notifications)
                Label("Search", systemImage: "magnifyingglass").tag(Route.search)
            }

            ForEach(app.visibleAccounts) { account in
                AccountSection(account: account, creatingBoard: $creatingBoard, creatingWorkspace: $creatingWorkspace)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { app.addingAccount = true } label: { Label("Add Server", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                Button { QuickAddController.shared.show() } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .buttonStyle(.borderless)
                    .help("Quick add a card (\(HotKeyCenter.shared.shortcut?.display ?? "⌃⌥Space"))")
            }
            .padding(10)
        }
        .sheet(item: $creatingBoard) { a in CreateBoardView(account: a).environment(app) }
        .sheet(item: $creatingWorkspace) { a in CreateWorkspaceView(account: a).environment(app) }
    }
}

private struct AccountSection: View {
    let account: Account
    @Binding var creatingBoard: Account?
    @Binding var creatingWorkspace: Account?
    @Environment(AppModel.self) private var app
    @AppStorage private var expanded: Bool

    init(account: Account, creatingBoard: Binding<Account?>, creatingWorkspace: Binding<Account?>) {
        self.account = account
        _creatingBoard = creatingBoard
        _creatingWorkspace = creatingWorkspace
        _expanded = AppStorage(wrappedValue: true, "hackban:sidebar-expanded:\(account.id)")
    }

    var body: some View {
        Section(isExpanded: $expanded) {
            if account.signedOut {
                Button { Task { await app.reauthenticate(account) } } label: {
                    Label("Signed out. Sign in again…", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else if !account.loaded {
                ProgressView().controlSize(.small)
            }
            let starred = account.starredBoards
            if !starred.isEmpty {
                ForEach(starred) { b in boardRow(b, star: true) }
            }
            ForEach(account.workspaces) { w in
                DisclosureGroup {
                    ForEach(w.boards) { b in boardRow(b) }
                } label: {
                    HStack(spacing: 6) {
                        WorkspaceLogo(name: w.name, logo: w.logo, account: account, size: 16)
                        Text(w.name)
                    }
                    .tag(Route.workspace(account: account.id, id: w.id))
                    .contextMenu {
                        Button("Open Workspace") { app.route = .workspace(account: account.id, id: w.id) }
                        Button("New Board…") { creatingBoard = account }
                    }
                }
            }
            if !account.guestBoards.isEmpty {
                DisclosureGroup("Guest boards") {
                    ForEach(account.guestBoards) { b in boardRow(b) }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Circle().fill(account.color).frame(width: 8, height: 8)
                Text(account.config.label)
                if account.unread > 0 { Text("\(account.unread)").font(.caption2.bold()).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Button("New Board…") { creatingBoard = account }
                    Button("New Workspace…") { creatingWorkspace = account }
                    Divider()
                    Button("Profile & Settings") { app.route = .profile(account: account.id) }
                    Button("Closed Boards") { app.route = .closedBoards(account: account.id) }
                    Button("Open in Browser") { NSWorkspace.shared.open(account.config.server) }
                    if account.profile?.isAdmin == true {
                        Button("Admin Panel (Browser)") { NSWorkspace.shared.open(account.client.webURL("/admin")) }
                        Button("Import from Trello (Browser)") { NSWorkspace.shared.open(account.client.webURL("/import")) }
                    }
                    Divider()
                    Button("Refresh") { Task { await account.refresh() } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func boardRow(_ b: BoardSummary, star: Bool = false) -> some View {
        HStack(spacing: 8) {
            BoardBackground(background: b.background)
                .frame(width: 18, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(b.name).lineLimit(1)
            if star { Spacer(); Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
        }
        .tag(Route.board(account: account.id, id: b.id))
        .contextMenu {
            Button(b.starred == true ? "Unstar" : "Star") {
                app.run(account) {
                    try await account.api.starBoard(b.id, !(b.starred ?? false))
                    await account.refresh()
                }
            }
            Button("Copy Link") { copyToPasteboard(account.client.webURL("/b/\(b.id)").absoluteString) }
            Button("Open in Browser") { NSWorkspace.shared.open(account.client.webURL("/b/\(b.id)")) }
        }
    }
}

struct WorkspaceLogo: View {
    let name: String
    let logo: String?
    let account: Account
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 5).fill(LinearGradient(colors: [Color(hex: "#0c66e4"), Color(hex: "#37b4c3")], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.white)
            if let logo {
                RemoteImage(account: account, url: logo) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5))
    }
}
