import HackbanKit
import SwiftUI
import UniformTypeIdentifiers

/// Drag payloads (plain strings so they work without registering custom types).
enum DragItem {
    static func card(_ id: String) -> String { "hackban-card:\(id)" }
    static func list(_ id: String) -> String { "hackban-list:\(id)" }
    static func cardId(_ s: String) -> String? { s.hasPrefix("hackban-card:") ? String(s.dropFirst(13)) : nil }
    static func listId(_ s: String) -> String? { s.hasPrefix("hackban-list:") ? String(s.dropFirst(13)) : nil }
}

struct BoardScreen: View {
    @Bindable var model: BoardModel
    @Environment(AppModel.self) private var app
    @State private var hoveredCard: String?
    @State private var showMenu = false
    @State private var showShare = false
    @State private var showFilters = false
    @State private var addingList = false
    @State private var newList = ""
    @State private var quickEdit: String?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let board = model.board {
                content(board)
            } else if model.deleted {
                ContentUnavailableView("This board isn't available", systemImage: "rectangle.slash", description: Text("It was deleted, or you no longer have access."))
            } else if let e = model.loadError {
                ContentUnavailableView {
                    Label("Couldn't load the board", systemImage: "exclamationmark.triangle")
                } description: { Text(e) } actions: { Button("Try Again") { Task { await model.load() } } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private func content(_ board: Board) -> some View {
        ZStack {
            BoardBackground(background: board.background, bgImage: board.bgImage, account: model.account).ignoresSafeArea()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(board.lists) { list in
                        ListColumn(model: model, list: list, hoveredCard: $hoveredCard)
                            .dropDestination(for: String.self) { items, _ in
                                guard let s = items.first else { return false }
                                if let lid = DragItem.listId(s) { model.moveList(lid, before: list.id); return true }
                                return false
                            }
                    }
                    if model.canEdit { addListColumn }
                }
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle(board.name)
        .navigationSubtitle(subtitle(board))
        .toolbar { toolbar(board) }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in handleKey(press, board) }
        .inspector(isPresented: $showMenu) { BoardInspector(model: model) { showMenu = false } }
        .sheet(isPresented: $showShare) { ShareBoardView(model: model).environment(app) }
    }

    @ToolbarContentBuilder
    private func toolbar(_ board: Board) -> some ToolbarContent {
        ToolbarItemGroup {
            // Inset, like the avatars below, so the chip clears the rounded end of its glass group.
            AccountTag(account: model.account)
                .padding(.horizontal, 4)
            Button { model.toggleStar() } label: {
                Image(systemName: board.starred ? "star.fill" : "star").foregroundStyle(board.starred ? Color.yellow : Color.secondary)
            }
            .help(board.starred ? "Unstar" : "Star")
            Menu {
                visibilityItems(board)
            } label: {
                Label(visibilityTitle(board.visibility), systemImage: visibilityIcon(board.visibility))
            }
            .help("Visibility")
            .disabled(!board.isAdmin)
            // Inset so the first avatar clears the rounded end of the toolbar's glass group.
            AvatarStack(users: board.members.map(\.user), account: model.account, size: 22, max: 6)
                .padding(.horizontal, 4)
            Button { showShare = true } label: { Label("Share", systemImage: "person.badge.plus") }
            Button { showFilters.toggle() } label: {
                Label("Filter", systemImage: model.filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .popover(isPresented: $showFilters) { FilterPopover(model: model) }
            Button { showMenu.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }.help("Board inspector (w)")
        }
        if model.sync.hasStatus {
            ToolbarItem { SyncStatusButton(account: model.account) }
        }
    }

    /// The workspace, and when it's offline, how old what's showing is.
    private func subtitle(_ board: Board) -> String {
        let workspace = board.workspace?.name ?? ""
        guard model.sync.isOffline else { return workspace }
        var offline = "Offline"
        if let at = model.sync.boardFetchedAt[board.id] { offline += ", updated \(at.formatted(.relative(presentation: .named)))" }
        return workspace.isEmpty ? offline : "\(workspace) · \(offline)"
    }

    @ViewBuilder
    private func visibilityItems(_ board: Board) -> some View {
        ForEach(["private", "workspace", "public"], id: \.self) { v in
            Button {
                model.updateBoard(.init(visibility: v))
            } label: {
                Label(visibilityTitle(v), systemImage: board.visibility == v ? "checkmark" : visibilityIcon(v))
            }
        }
    }

    private var addListColumn: some View {
        VStack(alignment: .leading) {
            if addingList {
                TextField("Enter list name…", text: $newList)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let n = newList.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty { model.addList(n) }
                        newList = ""
                    }
                    .onExitCommand { addingList = false }
                HStack {
                    Button("Add list") {
                        let n = newList.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty { model.addList(n) }
                        newList = ""
                    }
                    .buttonStyle(.borderedProminent)
                    Button { addingList = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            } else {
                Button { addingList = true } label: {
                    Label("Add another list", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
        .padding(10)
        .frame(width: 272)
        .background(addingList ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.white.opacity(0.24)), in: RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let lid = DragItem.listId(s) else { return false }
            model.moveList(lid, before: nil)
            return true
        }
    }

    /// The web app's hover shortcuts.
    private func handleKey(_ press: KeyPress, _ board: Board) -> KeyPress.Result {
        let key = press.characters
        if key == "w" { showMenu.toggle(); return .handled }
        if key == "q" {
            if let me = model.account.me { model.filters.members = model.filters.members == [me] ? [] : [me] }
            return .handled
        }
        if key == "x" { model.filters = CardFilters(); return .handled }
        if key == "/" { showFilters = true; return .handled }
        guard let id = hoveredCard, let card = model.card(id) else { return .ignored }
        switch press.key {
        case .return:
            app.open(card: id, in: model.account)
            return .handled
        case .space:
            if let me = model.account.me, let u = board.member(me)?.user ?? model.account.profile?.asUser { model.toggleMember(card: id, user: u) }
            return .handled
        default: break
        }
        guard board.canEdit else { return .ignored }
        switch key {
        case "e": quickEdit = id; NotificationCenter.default.post(name: .hackbanQuickEdit, object: id); return .handled
        case "d": model.updateCard(id, .init(dueComplete: !card.dueComplete)); return .handled
        case "c": model.updateCard(id, .init(closed: true)); return .handled
        case "1", "2", "3", "4", "5", "6", "7", "8", "9", "0":
            let n = key == "0" ? 9 : (Int(key) ?? 1) - 1
            if n < board.labels.count { model.toggleLabel(card: id, label: board.labels[n]) }
            return .handled
        default: return .ignored
        }
    }
}

extension Notification.Name {
    /// Object: card id. The card front opens its quick-edit popover.
    static let hackbanQuickEdit = Notification.Name("hackban.quickEdit")
}

func visibilityTitle(_ v: String) -> String {
    switch v {
    case "private": return "Private"
    case "public": return "Public"
    default: return "Workspace"
    }
}

func visibilityIcon(_ v: String) -> String {
    switch v {
    case "private": return "lock"
    case "public": return "globe"
    default: return "person.3"
    }
}

struct FilterPopover: View {
    @Bindable var model: BoardModel

    var body: some View {
        let board = model.board
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Filter").font(.headline)
                TextField("Keyword", text: $model.filters.query).textFieldStyle(.roundedBorder)
                Text("Members").font(.caption.bold()).foregroundStyle(.secondary)
                toggle("No members", key: "none", set: \.members)
                if let me = model.account.me { toggle("Cards assigned to me", key: me, set: \.members) }
                ForEach(board?.members ?? [], id: \.userId) { m in
                    if m.userId != model.account.me {
                        toggle(m.user.displayName, key: m.userId, set: \.members) { AvatarView(user: m.user, account: model.account, size: 18) }
                    }
                }
                Text("Due date").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(CardFilters.Due.allCases, id: \.self) { d in
                    Toggle(d.title, isOn: Binding(
                        get: { model.filters.due.contains(d) },
                        set: { on in if on { model.filters.due.insert(d) } else { model.filters.due.remove(d) } }
                    ))
                }
                Text("Labels").font(.caption.bold()).foregroundStyle(.secondary)
                toggle("No labels", key: "none", set: \.labels)
                ForEach(board?.labels ?? []) { l in
                    toggle(l.name, key: l.id, set: \.labels) { LabelChip(label: l, swatch: true) }
                }
                if model.filters.isActive {
                    Button("Clear filters (x)") { model.filters = CardFilters() }
                }
            }
            .padding(14)
        }
        .frame(width: 300, height: 460)
    }

    private func toggle(_ title: String, key: String, set: WritableKeyPath<CardFilters, Set<String>>) -> some View {
        toggle(title, key: key, set: set) { EmptyView() }
    }

    private func toggle<Icon: View>(_ title: String, key: String, set: WritableKeyPath<CardFilters, Set<String>>, @ViewBuilder icon: () -> Icon) -> some View {
        Toggle(isOn: Binding(
            get: { model.filters[keyPath: set].contains(key) },
            set: { on in if on { model.filters[keyPath: set].insert(key) } else { model.filters[keyPath: set].remove(key) } }
        )) {
            HStack(spacing: 6) { icon(); Text(title).lineLimit(1) }
        }
    }
}
