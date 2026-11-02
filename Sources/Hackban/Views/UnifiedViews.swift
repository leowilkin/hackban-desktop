import AppKit
import HackbanKit
import SwiftUI

/// Cards assigned to me on every account, grouped by when they're due.
struct MyCardsView: View {
    @Environment(AppModel.self) private var app
    @State private var loading = false
    @State private var done = false
    @State private var collapsed: Set<String> = []

    private struct Row: Identifiable {
        let account: Account
        let card: Card
        var id: String { "\(account.id)|\(card.id)" }
    }

    var body: some View {
        let rows = app.visibleAccounts.flatMap { a in a.myCards.map { Row(account: a, card: $0) } }.filter { $0.card.dueComplete == done }
        let groups: [(String, [Row])] = group(rows)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                PageTitle(title: "My Cards", detail: "\(rows.count) \(rows.count == 1 ? "card" : "cards")").padding(.horizontal, 24)
                FilterBar { PillTabs(selection: $done, options: [(false, "Open"), (true, "Done")]) }
                ForEach(groups, id: \.0) { group in
                    Section {
                        if !collapsed.contains(group.0) {
                            ForEach(group.1) { r in row(r) }
                        }
                    } header: {
                        GroupHeader(title: group.0, count: group.1.count, collapsed: Binding(
                            get: { collapsed.contains(group.0) },
                            set: { if $0 { collapsed.insert(group.0) } else { collapsed.remove(group.0) } }
                        ))
                    }
                }
            }
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if rows.isEmpty && !loading {
                if done {
                    ContentUnavailableView("Nothing done yet", systemImage: "checkmark.circle", description: Text("Cards you complete show up here."))
                } else {
                    ContentUnavailableView {
                        Label("Nothing assigned to you", systemImage: "person.crop.rectangle.stack")
                    } description: {
                        Text("Join a card with Space while hovering it, or with @me in quick add.")
                    } actions: {
                        Button("Quick Add a Card") { QuickAddController.shared.show() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle("My Cards")
        .hidingToolbarTitle()
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

    /// A card as Todoist draws a task: a circle, the title (and the description's first line), then a line of
    /// details with the board on the right, and a divider under it.
    private func row(_ r: Row) -> some View {
        let (doneItems, totalItems) = r.card.checkCounts
        let labels = (r.card.labels ?? []).map(\.label.name).filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    var c = r.card
                    c.dueComplete.toggle()
                    if let i = r.account.myCards.firstIndex(where: { $0.id == c.id }) { r.account.myCards[i] = c }
                    app.run(r.account) {
                        try await r.account.api.updateCard(c.id, .init(dueComplete: c.dueComplete))
                        await r.account.refreshMyCards()
                    }
                } label: {
                    Image(systemName: r.card.dueComplete ? "checkmark.circle.fill" : "circle")
                        .font(.title3.weight(.light))
                        .foregroundStyle(r.card.dueComplete ? Color(hex: "#1f845a") : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(r.card.dueComplete ? "Mark incomplete" : "Mark complete")
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.card.title).strikethrough(r.card.dueComplete).fixedSize(horizontal: false, vertical: true)
                    if let line = r.card.description.split(separator: "\n").first {
                        Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 12) {
                        due(r.card)
                        if !labels.isEmpty { Label(labels.joined(separator: ", "), systemImage: "tag").lineLimit(1) }
                        if totalItems > 0 { Label("\(doneItems)/\(totalItems)", systemImage: "checklist") }
                        Spacer(minLength: 12)
                        AccountTag(account: r.account)
                        if let b = r.card.list?.board {
                            HStack(spacing: 5) {
                                Text(b.name).lineLimit(1)
                                BoardBackground(background: b.background).frame(width: 12, height: 9).clipShape(RoundedRectangle(cornerRadius: 2))
                            }
                            .help([b.name, r.card.list?.name].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            Divider().padding(.leading, 30)
        }
        .modifier(ListRowStyle { app.open(card: r.card.id, in: r.account, board: r.card.list?.board?.id) })
    }

    /// The due date in Todoist's colours: red when overdue, green today, orange tomorrow.
    @ViewBuilder
    private func due(_ card: Card) -> some View {
        if let d = card.due {
            let cal = Calendar.current
            let text = cal.isDateInToday(d) ? "Today" : cal.isDateInTomorrow(d) ? "Tomorrow" : d.formatted(.dateTime.day().month(.abbreviated))
            let color: Color = card.dueComplete ? .secondary
                : d < Date() ? Color(hex: "#d1453b")
                : cal.isDateInToday(d) ? Color(hex: "#058527")
                : cal.isDateInTomorrow(d) ? Color(hex: "#ad6200")
                : .secondary
            Label(text, systemImage: "calendar").foregroundStyle(color)
        }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Notifications", detail: "\(app.totalUnread) unread", icon: "tray").padding(.horizontal, 24)
                FilterBar { PillTabs(selection: $unreadOnly, options: [(false, "All"), (true, "Unread")]) }
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(r.n.read ? Color.clear : Color.accentColor).frame(width: 7, height: 7).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.n.summary).fontWeight(r.n.read ? .regular : .semibold).lineLimit(2)
                                if let t = r.n.data["text"], !t.isEmpty { Text(t).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer(minLength: 16)
                            HStack(spacing: 8) {
                                if !r.n.read { Button("Mark read") { app.markRead(r.n, in: r.account) }.buttonStyle(.link) }
                                AccountTag(account: r.account)
                                Text(r.n.createdAt.relative).foregroundStyle(.secondary).help(r.n.createdAt.formatted())
                            }
                            .font(.callout)
                            .fixedSize()
                        }
                        .padding(.vertical, 10)
                        Divider().padding(.leading, 17)
                    }
                    .modifier(ListRowStyle {
                        app.markRead(r.n, in: r.account)
                        if let c = r.n.cardId { app.open(card: c, in: r.account, board: r.n.boardId) }
                    })
                }
            }
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(unreadOnly ? "You're all caught up" : "No notifications yet", systemImage: "tray",
                                       description: Text("Comments on cards you watch, and being added to cards, show up here."))
            }
        }
        .navigationTitle("Notifications")
        .hidingToolbarTitle()
        .toolbar {
            ToolbarItem {
                Button("Mark all read") { app.markAllRead() }.disabled(app.totalUnread == 0)
            }
        }
        .task { await app.pollNotifications() }
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
