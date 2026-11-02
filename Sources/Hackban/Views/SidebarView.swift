import AppKit
import HackbanKit
import SwiftUI

/// Sheet request for a new board, optionally in a given workspace.
struct NewBoard: Identifiable {
    let account: Account
    var workspaceId: String?
    var id: String { "\(account.id)|\(workspaceId ?? "")" }
}

// Each workspace is its own collapsible section rather than an expandable row: once any row in a sidebar can
// expand, macOS reserves a chevron gutter down every row, which pushed everything in.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var creatingBoard: NewBoard?
    @State private var creatingWorkspace: Account?

    var body: some View {
        @Bindable var app = app
        List(selection: $app.route) {
            Section {
                Button { SearchController.shared.show() } label: { navRow("Search", "magnifyingglass") }
                    .buttonStyle(.plain)
                    .help("Search boards and cards (⌘K)")
                navRow("Home", "house").tag(Route.home)
                navRow("My Cards", "person.crop.rectangle.stack")
                    .badge(app.visibleAccounts.reduce(0) { n, a in n + a.myCards.filter { !$0.dueComplete }.count })
                    .tag(Route.myCards)
                navRow("Notifications", "tray")
                    .badge(app.totalUnread)
                    .tag(Route.notifications)
            }

            if app.visibleAccounts.contains(where: { !$0.starredBoards.isEmpty }) {
                SavedSection("starred") {
                    ForEach(app.visibleAccounts) { a in
                        ForEach(a.starredBoards) { b in
                            BoardRow(board: b, account: a, showAccount: app.accounts.count > 1)
                                .tag(Route.board(account: a.id, id: b.id))
                        }
                    }
                } header: {
                    Text("Starred")
                }
            }

            ForEach(app.visibleAccounts) { account in
                AccountSections(account: account, creatingBoard: $creatingBoard, creatingWorkspace: $creatingWorkspace)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { syncStatus }
        .sheet(item: $creatingBoard) { n in CreateBoardView(account: n.account, workspaceId: n.workspaceId).environment(app) }
        .sheet(item: $creatingWorkspace) { a in CreateWorkspaceView(account: a).environment(app) }
    }

    /// The top of the sidebar, after Todoist's: the app's switcher menu, then a red Add card.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                Button("Add Server…") { app.addingAccount = true }
                Button("Join Board from Link…") { JoinLinkPanel.present(app: app) }
                Divider()
                SettingsLink { Text("Settings…") }
            } label: {
                HStack(spacing: 7) {
                    HackbanMark(size: 20)
                    Text("Hackban").fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { QuickAddController.shared.show() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.hackClubRed)
                    Text("Add card").fontWeight(.semibold).foregroundStyle(Color.hackClubRed)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quick add a card (\(HotKeyCenter.shared.shortcut?.display ?? "⌃⌥Space"))")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    /// How each server's sync is going, only while there's something to say (offline, waiting, failed).
    @ViewBuilder
    private var syncStatus: some View {
        let accounts = app.visibleAccounts.filter(\.sync.hasStatus)
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(accounts) { SyncStatusRow(account: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// Grey icons, as in Linear's sidebar, rather than accent-coloured ones.
    private func navRow(_ title: String, _ icon: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(.secondary) }
    }
}

/// A sidebar section that remembers whether it's collapsed.
private struct SavedSection<Content: View, Header: View>: View {
    @AppStorage private var expanded: Bool
    private let content: Content
    private let header: Header

    init(_ key: String, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        _expanded = AppStorage(wrappedValue: true, "hackban:sidebar-expanded:\(key)")
        self.content = content()
        self.header = header()
    }

    var body: some View {
        Section(isExpanded: $expanded) { content } header: { header }
    }
}

/// An account's workspaces, a section each, then its guest boards. The account's own status (signed out, loading)
/// gets a section of its own when there's something to say or no workspace to hang its menu on.
private struct AccountSections: View {
    let account: Account
    @Binding var creatingBoard: NewBoard?
    @Binding var creatingWorkspace: Account?
    @Environment(AppModel.self) private var app

    var body: some View {
        if account.signedOut || !account.loaded || account.workspaces.isEmpty {
            Section {
                if account.signedOut {
                    Button { Task { await app.reauthenticate(account) } } label: {
                        Label("Signed out. Sign in again…", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                } else if !account.loaded {
                    ProgressView().controlSize(.small)
                }
            } header: {
                header(account.config.label) { accountMenu }
            }
        }
        ForEach(account.workspaces) { w in
            SavedSection("\(account.id):\(w.id)") {
                ForEach(w.boards) { b in
                    BoardRow(board: b, account: account).tag(Route.board(account: account.id, id: b.id))
                }
            } header: {
                header(w.name) {
                    Button("Open Workspace") { app.route = .workspace(account: account.id, id: w.id) }
                    Button("New Board…") { creatingBoard = NewBoard(account: account, workspaceId: w.id) }
                    Divider()
                    accountMenu
                }
            }
        }
        if !account.guestBoards.isEmpty {
            SavedSection("\(account.id):guest") {
                ForEach(account.guestBoards) { b in
                    BoardRow(board: b, account: account).tag(Route.board(account: account.id, id: b.id))
                }
            } header: {
                header("Guest boards") { accountMenu }
            }
        }
    }

    /// The section title, with the account's colour and name when there's more than one account, and a menu.
    private func header<Items: View>(_ title: String, @ViewBuilder menu: () -> Items) -> some View {
        let items = menu()
        let several = app.accounts.count > 1
        return HStack(spacing: 6) {
            if several { Circle().fill(account.color).frame(width: 8, height: 8) }
            Text(title).lineLimit(1)
            if several && title != account.config.label { Text(account.config.label).foregroundStyle(.tertiary).lineLimit(1) }
            if account.sync.isOffline { Image(systemName: "icloud.slash").foregroundStyle(.secondary).help("Offline: can't reach \(account.host)") }
            // Next to the title rather than trailing: the collapse chevron only shows on hover and takes the
            // trailing edge, which pushed a trailing button sideways.
            Menu { items } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
        .contextMenu { items }
    }

    @ViewBuilder
    private var accountMenu: some View {
        Button("New Workspace…") { creatingWorkspace = account }
        Button("Profile & Settings") { app.route = .profile(account: account.id) }
        Button("Closed Boards") { app.route = .closedBoards(account: account.id) }
        Button("Open \(account.config.label) in Browser") { NSWorkspace.shared.open(account.config.server) }
        if account.profile?.isAdmin == true {
            Button("Admin Panel (Browser)") { NSWorkspace.shared.open(account.client.webURL("/admin")) }
            Button("Import from Trello (Browser)") { NSWorkspace.shared.open(account.client.webURL("/import")) }
        }
        Divider()
        Button("Refresh") { Task { await account.refresh() } }
    }
}

private struct BoardRow: View {
    let board: BoardSummary
    let account: Account
    var showAccount = false
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            BoardBackground(background: board.background)
                .frame(width: 18, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(board.name).lineLimit(1)
            if showAccount {
                Spacer()
                Circle().fill(account.color).frame(width: 6, height: 6).help(account.config.label)
            }
        }
        .contextMenu {
            Button(board.starred == true ? "Unstar" : "Star") {
                app.run(account) {
                    try await account.api.starBoard(board.id, !(board.starred ?? false))
                    await account.refresh()
                }
            }
            Button("Copy Link") { copyToPasteboard(account.client.webURL("/b/\(board.id)").absoluteString) }
            Button("Open in Browser") { NSWorkspace.shared.open(account.client.webURL("/b/\(board.id)")) }
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
