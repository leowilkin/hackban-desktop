import AppKit
import HackbanKit
import Observation
import SwiftUI

/// A floating, Spotlight-style panel that takes key input without bringing the main window forward.
final class QuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { QuickAddController.shared.hide() }
    }
}

@MainActor
final class QuickAddController: NSObject, NSWindowDelegate {
    static let shared = QuickAddController()
    private var panel: QuickAddPanel?
    private let state = QuickAddState()

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        state.prepare(app: AppModel.shared)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - f.height * 0.28 - p.frame.height))
        }
        p.makeKeyAndOrderFront(nil)
        state.focusToken += 1
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickAddPanel {
        let p = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 170),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = false
        p.backgroundColor = .clear
        p.delegate = self
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        let host = NSHostingView(rootView: QuickAddView(state: state).environment(AppModel.shared))
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        return p
    }

    /// Clicking anywhere else dismisses it, like Spotlight.
    func windowDidResignKey(_ notification: Notification) { hide() }
}

/// Everything the quick-add view edits, kept between showings.
@MainActor
@Observable
final class QuickAddState {
    var text = ""
    /// "account|board"
    var boardKey = ""
    var listId = ""
    var busy = false
    var error: String?
    var focusToken = 0
    /// Loaded boards (lists, labels, members), by "account|board".
    var details: [String: Board] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private weak var app: AppModel?

    struct Option: Identifiable, Hashable {
        let key: String
        let accountId: String
        let accountLabel: String
        let workspace: String
        let board: BoardSummary
        var id: String { key }
    }

    var parse: Bool { UserDefaults.standard.object(forKey: "hackban:quickadd:parse") as? Bool ?? true }

    func prepare(app: AppModel) {
        self.app = app
        error = nil
        let fixed = UserDefaults.standard.string(forKey: "hackban:quickadd:default") ?? ""
        let last = UserDefaults.standard.string(forKey: "hackban:quickadd:last") ?? ""
        let pick = !fixed.isEmpty ? fixed : last
        let parts = pick.split(separator: "|").map(String.init)
        if parts.count >= 2, options.contains(where: { $0.key == "\(parts[0])|\(parts[1])" }) {
            boardKey = "\(parts[0])|\(parts[1])"
            listId = parts.count > 2 ? parts[2] : ""
        } else if boardKey.isEmpty || !options.contains(where: { $0.key == boardKey }) {
            boardKey = options.first?.key ?? ""
            listId = ""
        }
        load(boardKey)
    }

    var options: [Option] {
        (app?.visibleAccounts ?? []).filter { !$0.signedOut }.flatMap { a in
            a.allBoards.map { Option(key: "\(a.id)|\($0.board.id)", accountId: a.id, accountLabel: a.config.label, workspace: $0.workspace, board: $0.board) }
        }
    }

    func account(for key: String) -> Account? {
        guard let id = key.split(separator: "|").first.map(String.init) else { return nil }
        return app?.account(id)
    }

    func load(_ key: String) {
        guard !key.isEmpty, details[key] == nil, !loading.contains(key), let a = account(for: key) else { return }
        let boardId = String(key.split(separator: "|")[1])
        // What's been downloaded first (so quick add works offline), then the server's latest.
        a.sync.loadCachedBoard(boardId)
        if let b = a.sync.boards[boardId] { loaded(b, key: key) }
        guard !a.sync.isOffline else { return }
        loading.insert(key)
        Task {
            defer { loading.remove(key) }
            let started = Date()
            if let b = try? await a.api.board(boardId) {
                a.sync.store(board: b, fetchStarted: started)
                loaded(a.sync.boards[boardId] ?? b, key: key)
            }
        }
    }

    private func loaded(_ b: Board, key: String) {
        details[key] = b
        if key == boardKey, listId.isEmpty || !b.lists.contains(where: { $0.id == listId }) { listId = b.lists.first?.id ?? "" }
    }

    /// Parser input: every board, with lists/labels/members where loaded.
    var parserBoards: [QuickAddParser.Board] {
        options.map { o in
            let d = details[o.key]
            return QuickAddParser.Board(
                key: o.key,
                name: o.board.name,
                lists: d?.lists.map { .init(id: $0.id, name: $0.name) } ?? [],
                labels: d?.labels ?? [],
                members: d?.members.map(\.user) ?? [],
                meId: account(for: o.key)?.me
            )
        }
    }

    var result: QuickAddParser.Result {
        let hour = UserDefaults.standard.object(forKey: "hackban:defaultDueHour") as? Int ?? 12
        guard parse else { return QuickAddParser.Result(title: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return QuickAddParser.parse(firstLine, boards: parserBoards, defaultBoard: boardKey, defaultHour: hour)
    }

    func submit(open: Bool) async -> Bool {
        let r = result
        let key = r.boardKey ?? boardKey
        guard let a = account(for: key), let app else { error = "Pick a board first."; return false }
        let boardId = String(key.split(separator: "|")[1])
        busy = true
        defer { busy = false }
        do {
            var board = details[key] ?? a.sync.boards[boardId]
            if board == nil {
                guard app.requireOnline(a) else { return false }
                let started = Date()
                let b = try await a.api.board(boardId)
                a.sync.store(board: b, fetchStarted: started)
                board = b
                details[key] = b
            }
            guard let board else { return false }
            let list = r.listId ?? (key == boardKey && board.lists.contains { $0.id == listId } ? listId : board.lists.first?.id)
            guard let list else { error = "\(board.name) has no lists."; return false }

            // Several pasted lines make one card each; only the first line's tokens are parsed,
            // and they apply to every card.
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let titles = lines.count > 1 ? [r.title] + lines.dropFirst() : [r.title]
            // Queued like any other edit, so it works offline and lands in order once it syncs.
            var last: String?
            for title in titles where !title.isEmpty {
                let id = TempID.make()
                last = id
                a.sync.perform(.createCard(id: id, listId: list, title: title, atTop: false), board: boardId)
                if let due = r.due {
                    a.sync.perform(.updateCard(id: id, patch: .init(due: .some(due)), base: .init(due: .some(nil))), board: boardId)
                }
                for l in r.labelIds {
                    if let label = board.label(l) { a.sync.perform(.setLabel(cardId: id, label: label, on: true, was: false), board: boardId) }
                }
                for m in r.memberIds {
                    if let user = board.member(m)?.user { a.sync.perform(.setMember(cardId: id, user: user, on: true, was: false), board: boardId) }
                }
            }
            UserDefaults.standard.set("\(key)|\(list)", forKey: "hackban:quickadd:last")
            let listName = board.lists.first { $0.id == list }?.name ?? ""
            let later = a.sync.isOffline ? " It'll sync when you're back online." : ""
            app.flash((titles.count > 1 ? "Added \(titles.count) cards to \(board.name) › \(listName)." : "Added to \(board.name) › \(listName).") + later)
            if open, let last {
                NSApp.activate(ignoringOtherApps: true)
                app.open(card: last, in: a, board: boardId)
            }
            text = ""
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct QuickAddView: View {
    @Bindable var state: QuickAddState
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var showHelp = false

    var body: some View {
        let r = state.result
        let options = state.options
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.rectangle").foregroundStyle(Color.hackClubRed).font(.title2)
                TextField("Add a card… e.g. Write post #Marketing @me !urgent tomorrow 5pm", text: $state.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { submit(open: false) }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) { submit(open: true); return .handled }
                        if press.modifiers.contains(.shift) { return .ignored }
                        submit(open: false)
                        return .handled
                    }
            }
            if !r.tokens.isEmpty || r.title != state.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                FlowLayout(spacing: 6) {
                    ForEach(Array(r.tokens.enumerated()), id: \.offset) { _, t in chip(t) }
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $state.boardKey) {
                    ForEach(options) { o in
                        Text(app.accounts.count > 1 ? "\(o.board.name) · \(o.accountLabel)" : o.board.name).tag(o.key)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .disabled(r.boardKey != nil)
                Picker("", selection: $state.listId) {
                    ForEach(state.details[state.boardKey]?.lists ?? []) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                .disabled(r.listId != nil)
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showHelp) { QuickAddHelp() }
                Text("↩ add  ⌘↩ add & open  ⎋ close").font(.caption).foregroundStyle(.secondary)
            }
            if let e = state.error { Text(e).font(.caption).foregroundStyle(.red) }
            if options.isEmpty { Text("Sign in to a Hackban server first (Settings → Accounts).").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16)
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: state.boardKey) { _, k in
            if let lists = state.details[k]?.lists, !lists.contains(where: { $0.id == state.listId }) { state.listId = lists.first?.id ?? "" }
            state.load(k)
        }
        .onChange(of: r.boardKey) { _, k in if let k { state.load(k) } }
        .onChange(of: state.focusToken) { _, _ in focused = true }
        .onAppear { focused = true }
    }

    private func chip(_ t: QuickAddParser.Token) -> some View {
        let (icon, color): (String, Color) = {
            switch t.kind {
            case .board: return ("rectangle.split.3x1", .blue)
            case .list: return ("list.bullet", .teal)
            case .member: return ("person", .purple)
            case .label: return ("tag", .orange)
            case .due: return ("calendar", .green)
            }
        }()
        return Label(t.display, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func submit(open: Bool) {
        guard !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !state.busy else { return }
        Task {
            if await state.submit(open: open) { QuickAddController.shared.hide() }
        }
    }
}

struct QuickAddHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick add syntax").font(.headline)
            Group {
                Text("**#board** or **#board/list**: pick a board (a prefix is enough)")
                Text("**/list**: pick a list")
                Text("**@me**, **@name**: assign members")
                Text("**!label**: add a label (name or colour)")
                Text("**today**, **tomorrow 5pm**, **fri**, **next week**, **in 3 days**, **jan 5**: due date")
                Text("Paste several lines to add one card per line.")
                Text("Only tokens that match something are used; everything else stays in the title.").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 380)
    }
}
