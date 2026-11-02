import AppKit
import HackbanKit
import SwiftUI
import UniformTypeIdentifiers

/// The web's board menu as an inspector beside the board: about, background, labels, archived items, activity,
/// copy/move, export, close, delete. Icon tabs along the top, like Xcode's inspector.
struct BoardInspector: View {
    @Bindable var model: BoardModel
    let close: () -> Void
    @State private var tab: Tab = .about

    enum Tab: String, CaseIterable, Identifiable {
        case about = "About", background = "Background", labels = "Labels", archived = "Archived", activity = "Activity", more = "More"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .about: return "info.circle"
            case .background: return "photo"
            case .labels: return "tag"
            case .archived: return "archivebox"
            case .activity: return "clock.arrow.circlepath"
            case .more: return "ellipsis.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        Image(systemName: t.icon)
                            .symbolVariant(tab == t ? .fill : .none)
                            .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(t.rawValue)
                    .accessibilityLabel(t.rawValue)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            Text(tab.rawValue).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
            Group {
                switch tab {
                case .about: AboutBoard(model: model)
                case .background: BackgroundTab(model: model)
                case .labels: LabelsTab(model: model)
                case .archived: ArchivedTab(model: model)
                case .activity: ActivityTab(model: model)
                case .more: MoreTab(model: model, close: close)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
    }
}

private struct AboutBoard: View {
    @Bindable var model: BoardModel
    @State private var description = ""
    @State private var editing = false

    var body: some View {
        if let b = model.board {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Board admins").font(.headline)
                    ForEach(b.members.filter { $0.role == "admin" }, id: \.userId) { m in
                        HStack { AvatarView(user: m.user, account: model.account, size: 32); Text(m.user.displayName) }
                    }
                    Text("Description").font(.headline)
                    if editing {
                        TextEditor(text: $description).frame(minHeight: 160).border(.separator)
                        HStack {
                            Button("Save") { model.updateBoard(.init(description: description)); editing = false }.buttonStyle(.borderedProminent)
                            Button("Cancel") { editing = false }
                        }
                    } else {
                        if let d = b.description, !d.isEmpty { MarkdownText(text: d) } else { Text("No description yet.").foregroundStyle(.secondary) }
                        if b.canEdit { Button("Edit description") { description = b.description ?? ""; editing = true } }
                    }
                    Text("Board name").font(.headline)
                    if b.canEdit {
                        InlineEditor(value: b.name) { model.updateBoard(.init(name: $0)) }
                    } else {
                        Text(b.name)
                    }
                }
                .padding()
            }
        }
    }
}

private struct BackgroundTab: View {
    @Bindable var model: BoardModel
    @State private var imageURL = ""

    var body: some View {
        if let b = model.board {
            VStack(alignment: .leading, spacing: 14) {
                BoardBackground(background: b.background, bgImage: b.bgImage, account: model.account).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                BackgroundPicker(selection: Binding(get: { b.background }, set: { model.updateBoard(.init(background: $0)) }))
                    .disabled(!b.canEdit)
                Text("Image").font(.headline)
                TextField("https://…", text: $imageURL).textFieldStyle(.roundedBorder)
                    .disabled(!b.canEdit)
                HStack {
                    Button("Set image") {
                        let u = imageURL.trimmingCharacters(in: .whitespaces)
                        guard u.hasPrefix("https://") else { model.app.flash("Images must be an https URL."); return }
                        model.updateBoard(.init(bgImage: .some(u)))
                    }
                    if b.bgImage != nil { Button("Remove") { model.updateBoard(.init(bgImage: .some(nil))) } }
                }
                .disabled(!b.canEdit)
            }
            .padding()
            .onAppear { imageURL = b.bgImage ?? "" }
        }
    }
}

private struct LabelsTab: View {
    @Bindable var model: BoardModel
    @State private var editing: HackbanKit.Label?
    @State private var creating = false

    var body: some View {
        if let b = model.board {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if creating || editing != nil {
                        LabelEditor(label: editing, board: model) { creating = false; editing = nil }
                    } else {
                        ForEach(b.labels) { l in
                            HStack {
                                LabelChip(label: l, swatch: true).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(b.lists.flatMap(\.openCards).filter { $0.labelIds.contains(l.id) }.count) cards").font(.caption).foregroundStyle(.secondary)
                                if b.canEdit { Button { editing = l } label: { Image(systemName: "pencil") }.buttonStyle(.borderless) }
                            }
                        }
                        if b.canEdit { Button("Create a new label") { creating = true } }
                    }
                }
                .padding()
            }
        }
    }
}

private struct ArchivedTab: View {
    @Bindable var model: BoardModel
    @Environment(AppModel.self) private var app
    @State private var items: ArchivedItems?
    @State private var showLists = false
    @State private var q = ""
    @State private var confirm: ConfirmAction?

    var body: some View {
        VStack(alignment: .leading) {
            Picker("", selection: $showLists) { Text("Cards").tag(false); Text("Lists").tag(true) }.pickerStyle(.segmented).labelsHidden()
            TextField("Search archive…", text: $q).textFieldStyle(.roundedBorder)
            if let items {
                List {
                    if showLists {
                        ForEach(items.lists.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }) { l in
                            HStack {
                                Text(l.name)
                                Spacer()
                                restoreButton { act { try await model.api.updateList(l.id, closed: false) } }
                                deleteButton {
                                    confirm = ConfirmAction(title: "Delete \(l.name)?", message: "The list and its cards are deleted for good.", button: "Delete") {
                                        act { try await model.api.deleteList(l.id) }
                                    }
                                }
                            }
                        }
                    } else {
                        ForEach(items.cards.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }) { c in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(c.title)
                                    Text(c.list?.name ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                .onTapGesture { app.open(card: c.id, in: model.account) }
                                Spacer()
                                restoreButton { act { try await model.api.updateCard(c.id, .init(closed: false)) } }
                                deleteButton {
                                    confirm = ConfirmAction(title: "Delete card?", message: "\(c.title) is deleted for good. There is no undo.", button: "Delete") {
                                        act { try await model.api.deleteCard(c.id) }
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if showLists ? items.lists.isEmpty : items.cards.isEmpty {
                        ContentUnavailableView(showLists ? "No archived lists" : "No archived cards", systemImage: "archivebox")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .task { await reload() }
        .confirm($confirm)
    }

    private func reload() async {
        items = try? await model.api.archived(model.boardId)
    }

    // Icons rather than "Restore" and "Delete" in words, which left no room for titles in the inspector.
    private func restoreButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).help("Send back to the board")
    }

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
    }

    private func act(_ op: @escaping () async throws -> Void) {
        guard app.requireOnline(model.account) else { return }
        Task {
            do { try await op() } catch { app.flash(app.message(for: error)) }
            await reload()
            await model.load()
        }
    }
}

struct ActivityTab: View {
    @Bindable var model: BoardModel
    @Environment(AppModel.self) private var app
    @State private var items: [Activity] = []
    @State private var next: String?
    @State private var loading = false

    var body: some View {
        List {
            ForEach(items) { a in ActivityRow(activity: a, account: model.account) }
            if next != nil {
                Button("Load more") { Task { await load(more: true) } }.disabled(loading)
            }
        }
        // Rows on the inspector's glass, not on a slab of the list's own background.
        .scrollContentBackground(.hidden)
        .task { await load(more: false) }
    }

    private func load(more: Bool) async {
        loading = true
        defer { loading = false }
        if let page = try? await model.api.boardActivity(model.boardId, cursor: more ? next : nil) {
            items = more ? items + page.items : page.items
            next = page.next
        }
    }
}

struct ActivityRow: View {
    let activity: Activity
    let account: Account
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top) {
            AvatarView(user: activity.actor, account: account, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                (Text(activity.actor?.displayName ?? "Someone").bold() + Text(" ") + Text(ActivityText.describe(activity)))
                HStack(spacing: 6) {
                    if let b = activity.board { Text(b.name).font(.caption).foregroundStyle(.secondary) }
                    Text(activity.createdAt.relative).font(.caption).foregroundStyle(.secondary).help(activity.createdAt.formatted())
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let c = activity.card { app.open(card: c.id, in: account, board: activity.boardId) }
        }
    }
}

private struct MoreTab: View {
    @Bindable var model: BoardModel
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @State private var copyName = ""
    @State private var copyWorkspace = ""
    @State private var keepCards = true
    @State private var moveWorkspace = ""
    @State private var confirm: ConfirmAction?

    var body: some View {
        if let b = model.board {
            Form {
                Section("Watch") {
                    Text("Watch individual cards from the card's sidebar; you're notified of comments on cards you watch.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Copy board") {
                    TextField("Title", text: $copyName)
                    Picker("Workspace", selection: $copyWorkspace) { ForEach(model.account.workspaces) { Text($0.name).tag($0.id) } }
                    Toggle("Keep cards", isOn: $keepCards)
                    Button("Create copy") {
                        Task {
                            do {
                                let nb = try await model.api.copyBoard(b.id, name: copyName.isEmpty ? "\(b.name) (copy)" : copyName, workspaceId: copyWorkspace, keepCards: keepCards)
                                await model.account.refresh()
                                app.open(board: nb.id, in: model.account)
                                close()
                            } catch { app.flash(error.localizedDescription) }
                        }
                    }
                }
                if b.isAdmin {
                    Section("Move board") {
                        Picker("To workspace", selection: $moveWorkspace) { ForEach(model.account.workspaces) { Text($0.name).tag($0.id) } }
                        Button("Move") {
                            Task {
                                do {
                                    try await model.api.moveBoard(b.id, workspaceId: moveWorkspace)
                                    await model.load()
                                    await model.account.refresh()
                                } catch { app.flash(error.localizedDescription) }
                            }
                        }
                        .disabled(moveWorkspace == b.workspaceId)
                    }
                }
                Section("Export") {
                    Button("Export as JSON…") { export(b) }
                    Button("Copy board link") { copyToPasteboard(model.account.client.webURL("/b/\(b.id)").absoluteString) }
                    Button("Open in browser") { NSWorkspace.shared.open(model.account.client.webURL("/b/\(b.id)")) }
                }
                if b.isAdmin {
                    Section("Danger zone") {
                        Button(b.closed ? "Reopen board" : "Close board") {
                            model.updateBoard(.init(closed: !b.closed))
                            if !b.closed { app.route = .home; close() }
                        }
                        Button("Delete board…", role: .destructive) {
                            confirm = ConfirmAction(title: "Delete \(b.name)?", message: "All lists, cards and actions are deleted, and you can't reopen the board. There is no undo.", button: "Delete") {
                                Task {
                                    do {
                                        try await model.api.deleteBoard(b.id)
                                        await model.account.refresh()
                                        app.route = .home
                                        close()
                                    } catch { app.flash(error.localizedDescription) }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .confirm($confirm)
            .onAppear {
                copyName = "\(b.name) (copy)"
                copyWorkspace = b.workspaceId
                moveWorkspace = b.workspaceId
            }
        }
    }

    private func export(_ b: Board) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(b.name).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await model.api.exportBoard(b.id)
                try data.write(to: url)
            } catch { app.flash(error.localizedDescription) }
        }
    }
}

/// Members, roles, email invites and the join link.
struct ShareBoardView: View {
    @Bindable var model: BoardModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var results: [User] = []
    @State private var role = "normal"
    @State private var link: InviteLink?

    var body: some View {
        if let b = model.board {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Share board").font(.title2.bold())
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                HStack {
                    TextField("Name, username or email address", text: $q).textFieldStyle(.roundedBorder)
                    Picker("", selection: $role) {
                        Text("Member").tag("normal")
                        Text("Observer").tag("observer")
                        if b.isAdmin { Text("Admin").tag("admin") }
                    }
                    .labelsHidden().fixedSize()
                    if q.contains("@") && q.contains(".") {
                        Button("Invite") { model.addMember(email: q.trimmingCharacters(in: .whitespaces), role: role); q = "" }
                    }
                }
                if !results.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(results) { u in
                            Button {
                                model.addMember(userId: u.id, role: role)
                                q = ""
                                results = []
                            } label: {
                                HStack {
                                    AvatarView(user: u, account: model.account, size: 24)
                                    Text(u.displayName)
                                    if let un = u.username { Text("@\(un)").foregroundStyle(.secondary) }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                if b.isAdmin || b.inviteToken != nil {
                    GroupBox("Invite link") {
                        VStack(alignment: .leading, spacing: 8) {
                            let token = link?.inviteToken ?? b.inviteToken
                            if let token {
                                let url = model.account.client.webURL("/join/\(token)").absoluteString
                                HStack {
                                    Text(url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Button("Copy") { copyToPasteboard(url); app.flash("Link copied") }
                                }
                                if b.isAdmin {
                                    HStack {
                                        Picker("Joins as", selection: Binding(get: { link?.inviteRole ?? b.inviteRole ?? "normal" }, set: { r in setLink(enabled: true, role: r) })) {
                                            Text("Member").tag("normal")
                                            Text("Observer").tag("observer")
                                        }
                                        .fixedSize()
                                        Button("Reset link") { setLink(enabled: true, reset: true) }
                                        Button("Turn off link") { setLink(enabled: false) }
                                    }
                                }
                            } else if b.isAdmin {
                                Text("Anyone with the link can join this board as a guest, without joining the workspace.").font(.caption).foregroundStyle(.secondary)
                                Button("Create link") { setLink(enabled: true) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text("Board members").font(.headline)
                List {
                    ForEach(b.members, id: \.userId) { m in
                        HStack {
                            AvatarView(user: m.user, account: model.account, size: 28)
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(m.user.displayName)
                                    if m.userId == model.account.me { Text("(you)").foregroundStyle(.secondary) }
                                    if m.guest == true { Text("Guest").font(.caption.bold()).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                                }
                                if m.user.isGhost == true {
                                    Text(m.user.invitedEmail != nil ? "Invited, hasn't logged in yet" : "Imported from Trello").font(.caption).foregroundStyle(.secondary)
                                } else if let un = m.user.username {
                                    Text("@\(un)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if b.isAdmin {
                                Picker("", selection: Binding(get: { m.role }, set: { model.addMember(userId: m.userId, role: $0) })) {
                                    Text("Admin").tag("admin")
                                    Text("Member").tag("normal")
                                    Text("Observer").tag("observer")
                                }
                                .labelsHidden().fixedSize()
                            } else {
                                Text(m.role == "normal" ? "Member" : m.role.capitalized).foregroundStyle(.secondary)
                            }
                            if b.isAdmin || m.userId == model.account.me {
                                Button(m.userId == model.account.me ? "Leave" : "Remove") {
                                    model.removeMember(m.userId)
                                    if m.userId == model.account.me { dismiss() }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(width: 600, height: 620)
            .task(id: q) {
                let query = q.trimmingCharacters(in: .whitespaces)
                guard query.count >= 2 else { results = []; return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let found = (try? await model.api.searchUsers(query)) ?? []
                let existing = Set(b.members.map(\.userId))
                results = found.filter { !existing.contains($0.id) }
            }
        }
    }

    private func setLink(enabled: Bool, role: String? = nil, reset: Bool = false) {
        Task {
            do {
                link = try await model.api.setInviteLink(model.boardId, enabled: enabled, role: role, reset: reset)
                await model.load()
            } catch { app.flash(error.localizedDescription) }
        }
    }
}
