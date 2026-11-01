import AppKit
import HackbanKit
import SwiftUI

/// Cards assigned to me on every account, grouped by when they're due.
struct MyCardsView: View {
    @Environment(AppModel.self) private var app
    @State private var loading = false

    private struct Row: Identifiable {
        let account: Account
        let card: Card
        var id: String { "\(account.id)|\(card.id)" }
    }

    var body: some View {
        let rows = app.visibleAccounts.flatMap { a in a.myCards.map { Row(account: a, card: $0) } }
        let groups: [(String, [Row])] = group(rows)
        List {
            if rows.isEmpty && !loading {
                Text("Nothing assigned to you. Join a card with Space while hovering it, or with @me in quick add.").foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { r in row(r) }
                }
            }
        }
        .navigationTitle("My Cards")
        .toolbar {
            ToolbarItem { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") } }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        await withTaskGroup(of: Void.self) { g in
            for a in app.visibleAccounts { g.addTask { await a.refreshMyCards() } }
        }
        loading = false
    }

    private func group(_ rows: [Row]) -> [(String, [Row])] {
        let cal = Calendar.current
        let now = Date()
        let endToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let endWeek = cal.date(byAdding: .day, value: 7, to: endToday)!
        var buckets: [String: [Row]] = [:]
        for r in rows {
            let key: String
            if let d = r.card.due, !r.card.dueComplete {
                key = d < now ? "Overdue" : d < endToday ? "Today" : d < endWeek ? "This week" : "Later"
            } else if r.card.dueComplete {
                key = "Done"
            } else {
                key = "No due date"
            }
            buckets[key, default: []].append(r)
        }
        return ["Overdue", "Today", "This week", "Later", "No due date", "Done"].compactMap { k in
            buckets[k].map { (k, $0.sorted { ($0.card.due ?? .distantFuture) < ($1.card.due ?? .distantFuture) }) }
        }
    }

    private func row(_ r: Row) -> some View {
        HStack(spacing: 10) {
            Button {
                var c = r.card
                c.dueComplete.toggle()
                if let i = r.account.myCards.firstIndex(where: { $0.id == c.id }) { r.account.myCards[i] = c }
                app.run(r.account) {
                    try await r.account.api.updateCard(c.id, .init(dueComplete: c.dueComplete))
                    await r.account.refreshMyCards()
                }
            } label: {
                Image(systemName: r.card.dueComplete ? "checkmark.circle.fill" : "circle").foregroundStyle(r.card.dueComplete ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.card.title).strikethrough(r.card.dueComplete)
                HStack(spacing: 6) {
                    AccountTag(account: r.account)
                    if let b = r.card.list?.board {
                        BoardBackground(background: b.background).frame(width: 12, height: 9).clipShape(RoundedRectangle(cornerRadius: 2))
                        Text(b.name)
                    }
                    if let l = r.card.list?.name { Text("· \(l)") }
                    ForEach(r.card.labels ?? [], id: \.labelId) { LabelChip(label: $0.label, compact: true) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            DueBadge(card: r.card)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.open(card: r.card.id, in: r.account, board: r.card.list?.board?.id) }
    }
}

struct NotificationsView: View {
    @Environment(AppModel.self) private var app
    @State private var unreadOnly = false

    private struct Row: Identifiable {
        let account: Account
        let n: HackbanNotification
        var id: String { "\(account.id)|\(n.id)" }
    }

    var body: some View {
        let rows = app.visibleAccounts.flatMap { a in a.notifications.map { Row(account: a, n: $0) } }
            .filter { !unreadOnly || !$0.n.read }
            .sorted { $0.n.createdAt > $1.n.createdAt }
        List {
            if rows.isEmpty { Text(unreadOnly ? "No unread notifications." : "No notifications.").foregroundStyle(.secondary) }
            ForEach(rows) { r in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(r.n.read ? Color.clear : Color.accentColor).frame(width: 8, height: 8).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.n.summary).bold(!r.n.read)
                        if let t = r.n.data["text"], !t.isEmpty { Text(t).foregroundStyle(.secondary).lineLimit(3) }
                        HStack { AccountTag(account: r.account); Text(r.n.createdAt.relative) }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !r.n.read { Button("Mark read") { app.markRead(r.n, in: r.account) }.buttonStyle(.link) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    app.markRead(r.n, in: r.account)
                    if let c = r.n.cardId { app.open(card: c, in: r.account, board: r.n.boardId) }
                }
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItemGroup {
                Toggle("Unread only", isOn: $unreadOnly)
                Button("Mark all read") { app.markAllRead() }.disabled(app.totalUnread == 0)
            }
        }
        .task { await app.pollNotifications() }
    }
}

/// Search boards and cards on every account at once.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var q = ""
    @State private var results: [(Account, SearchResults)] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search boards and cards on every server", text: $q)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .padding()
            List {
                if searching { ProgressView() }
                ForEach(results, id: \.0.id) { pair in
                    let a = pair.0, r = pair.1
                    if !r.boards.isEmpty {
                        Section("Boards" + (app.accounts.count > 1 ? " · \(a.config.label)" : "")) {
                            ForEach(r.boards) { b in
                                HStack {
                                    BoardBackground(background: b.background).frame(width: 30, height: 22).clipShape(RoundedRectangle(cornerRadius: 3))
                                    Text(b.name)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { app.open(board: b.id, in: a) }
                            }
                        }
                    }
                    if !r.cards.isEmpty {
                        Section("Cards" + (app.accounts.count > 1 ? " · \(a.config.label)" : "")) {
                            ForEach(r.cards) { c in
                                VStack(alignment: .leading) {
                                    Text(c.title)
                                    Text("\(c.list?.board?.name ?? "") · \(c.list?.name ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { app.open(card: c.id, in: a, board: c.list?.board?.id) }
                            }
                        }
                    }
                }
                if !searching && q.count >= 2 && results.allSatisfy({ $0.1.boards.isEmpty && $0.1.cards.isEmpty }) {
                    Text("Nothing found for \"\(q)\".").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Search")
        .onAppear { focused = true }
        .task(id: q) {
            let query = q.trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else { results = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            searching = true
            var out: [(Account, SearchResults)] = []
            for a in app.visibleAccounts where !a.signedOut {
                if let r = try? await a.api.search(query) { out.append((a, r)) }
            }
            if !Task.isCancelled { results = out }
            searching = false
        }
    }
}

/// ⌘K: jump to any board on any account.
struct BoardPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var selected = 0

    private struct Item: Identifiable {
        let account: Account
        let workspace: String
        let board: BoardSummary
        var id: String { "\(account.id)|\(board.id)" }
    }

    var body: some View {
        let items = matches
        VStack(spacing: 0) {
            TextField("Go to board…", text: $q)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .onSubmit { if items.indices.contains(selected) { go(items[selected]) } }
                .onKeyPress(.downArrow) { selected = min(selected + 1, max(items.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
            Divider()
            ScrollViewReader { proxy in
                List(Array(items.enumerated()), id: \.element.id) { pair in
                    let i = pair.offset, item = pair.element
                    HStack {
                        BoardBackground(background: item.board.background).frame(width: 26, height: 18).clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(item.board.name)
                        Text(item.workspace).foregroundStyle(.secondary)
                        Spacer()
                        AccountTag(account: item.account)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(i == selected ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { go(item) }
                    .id(i)
                }
                .onChange(of: selected) { _, s in proxy.scrollTo(s) }
            }
        }
        .frame(width: 520, height: 420)
        .onChange(of: q) { _, _ in selected = 0 }
        .onExitCommand { dismiss() }
    }

    private var matches: [Item] {
        let all = app.visibleAccounts.flatMap { a in a.allBoards.map { Item(account: a, workspace: $0.workspace, board: $0.board) } }
        guard !q.isEmpty else {
            let recent = app.visibleAccounts.flatMap { a in a.recent.map { Item(account: a, workspace: "Recent", board: $0) } }
            return recent + all.filter { i in !recent.contains { $0.id == i.id } }
        }
        let n = q.lowercased()
        return all.filter { $0.board.name.lowercased().contains(n) || $0.workspace.lowercased().contains(n) }
            .sorted { ($0.board.name.lowercased().hasPrefix(n) ? 0 : 1) < ($1.board.name.lowercased().hasPrefix(n) ? 0 : 1) }
    }

    private func go(_ item: Item) {
        app.open(board: item.board.id, in: item.account)
        dismiss()
    }
}

/// Paste a /join/<token> link from any server you're signed in to.
enum JoinLinkPanel {
    @MainActor
    static func present(app: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Join a board from an invite link"
        alert.informativeText = "Paste a Hackban invite link (…/join/…)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://hackban.hackclub.com/join/…"
        if let s = NSPasteboard.general.string(forType: .string), s.contains("/join/") { field.stringValue = s }
        alert.accessoryView = field
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        guard let i = url.pathComponents.firstIndex(of: "join"), i + 1 < url.pathComponents.count else { app.flash("That isn't an invite link."); return }
        let token = url.pathComponents[i + 1]
        guard let account = app.accounts.first(where: { $0.config.server.host == url.host }) else {
            app.flash("Add \(url.host ?? "that server") as a server first.")
            return
        }
        Task {
            do {
                let preview = try await account.api.invitePreview(token: token)
                if !preview.alreadyMember {
                    let confirm = NSAlert()
                    confirm.messageText = "Join \(preview.name)?"
                    confirm.informativeText = "You'll join as a guest \(preview.inviteRole == "observer" ? "observer" : "member") of this board in \(preview.workspace?.name ?? "its workspace")."
                    confirm.addButton(withTitle: "Join")
                    confirm.addButton(withTitle: "Cancel")
                    guard confirm.runModal() == .alertFirstButtonReturn else { return }
                }
                let boardId = try await account.api.joinByInvite(token: token)
                await account.refresh()
                app.open(board: boardId, in: account)
            } catch { app.flash(error.localizedDescription) }
        }
    }
}
