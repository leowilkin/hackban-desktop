import AppKit
import HackbanKit
import Observation
import SwiftUI

/// A floating, Spotlight-style panel that takes key input without bringing the main window forward. Quick add and
/// search both use one.
final class FloatingPanel: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    static func make<Content: View>(width: CGFloat, height: CGFloat, delegate: NSWindowDelegate, content: Content) -> FloatingPanel {
        let p = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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
        p.delegate = delegate
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        return p
    }

    /// Centred on the screen with the mouse, a little above the middle, like Spotlight.
    func present() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - f.height * 0.28 - frame.height))
        }
        makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class QuickAddController: NSObject, NSWindowDelegate {
    static let shared = QuickAddController()
    private var panel: FloatingPanel?
    private let state = QuickAddState()

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        state.prepare(app: AppModel.shared)
        p.present()
        state.focusToken += 1
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel.make(width: 620, height: 320, delegate: self, content: QuickAddView(state: state).environment(AppModel.shared))
        p.onCancel = { QuickAddController.shared.hide() }
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
        loading.insert(key)
        Task {
            defer { loading.remove(key) }
            if let b = try? await a.api.board(boardId) {
                details[key] = b
                if key == boardKey, listId.isEmpty || !b.lists.contains(where: { $0.id == listId }) { listId = b.lists.first?.id ?? "" }
            }
        }
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
            var board = details[key]
            if board == nil { board = try await a.api.board(boardId); details[key] = board }
            guard let board else { return false }
            let list = r.listId ?? (key == boardKey && board.lists.contains { $0.id == listId } ? listId : board.lists.first?.id)
            guard let list else { error = "\(board.name) has no lists."; return false }

            // Several pasted lines make one card each; only the first line's tokens are parsed,
            // and they apply to every card.
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let titles = lines.count > 1 ? [r.title] + lines.dropFirst() : [r.title]
            var last: Card?
            for title in titles where !title.isEmpty {
                let card = try await a.api.createCard(listId: list, title: title)
                last = card
                if let due = r.due { try await a.api.updateCard(card.id, .init(due: .some(due))) }
                for l in r.labelIds { try await a.api.toggleLabel(card: card.id, label: l, on: true) }
                for m in r.memberIds { try await a.api.toggleMember(card: card.id, user: m, on: true) }
            }
            UserDefaults.standard.set("\(key)|\(list)", forKey: "hackban:quickadd:last")
            app.boardModel(account: a, boardId: boardId).scheduleReload()
            let listName = board.lists.first { $0.id == list }?.name ?? ""
            app.flash(titles.count > 1 ? "Added \(titles.count) cards to \(board.name) › \(listName)" : "Added to \(board.name) › \(listName)")
            if open, let last {
                NSApp.activate(ignoringOtherApps: true)
                app.open(card: last.id, in: a, board: boardId)
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    TextField("Add a card…", text: $state.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title2)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { submit(open: false) }
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.command) { submit(open: true); return .handled }
                            if press.modifiers.contains(.shift) { return .ignored }
                            submit(open: false)
                            return .handled
                        }
                    if state.busy { ProgressView().controlSize(.small).frame(height: 22) }
                }
                tokens(r)
                if let e = state.error {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(e)
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                }
            }
            .padding(16)
            Divider()
            HStack(spacing: 6) {
                if options.isEmpty {
                    Text("Sign in to a Hackban server first (Settings → Accounts).").font(.callout).foregroundStyle(.secondary)
                } else {
                    destination(r, options)
                }
                Spacer(minLength: 12)
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle").font(.body) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Quick add syntax")
                    .popover(isPresented: $showHelp) { QuickAddHelp() }
                HStack(spacing: 3) {
                    Text("Add & Open").padding(.trailing, 3)
                    Keycap(symbol: "command")
                    Keycap(symbol: "return")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, 4)
                .padding(.trailing, 2)
                Button { submit(open: false) } label: {
                    HStack(spacing: 6) {
                        Text("Add")
                        Image(systemName: "return").font(.caption.weight(.semibold)).opacity(0.7)
                    }
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.hackClubRed)
                .disabled(state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.busy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 620)
        .modifier(PanelSurface())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: state.boardKey) { _, k in
            if let lists = state.details[k]?.lists, !lists.contains(where: { $0.id == state.listId }) { state.listId = lists.first?.id ?? "" }
            state.load(k)
        }
        .onChange(of: r.boardKey) { _, k in if let k { state.load(k) } }
        .onChange(of: state.focusToken) { _, _ in focused = true }
        .onAppear { focused = true }
    }

    /// What the parser picked out of the text, or a hint at the syntax until it finds something.
    @ViewBuilder
    private func tokens(_ r: QuickAddParser.Result) -> some View {
        let lines = state.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !r.tokens.isEmpty || lines.count > 1 {
            FlowLayout(spacing: 6) {
                ForEach(Array(r.tokens.enumerated()), id: \.offset) { _, t in chip(t) }
                if lines.count > 1 { TokenChip(text: "\(lines.count) cards", icon: "square.stack", color: .secondary) }
            }
        } else if state.parse {
            Text("Type \(hint("#board")), \(hint("/list")), \(hint("@me")), \(hint("!label")) or a date like \(hint("tomorrow 5pm"))")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(height: 22)
        }
    }

    private func hint(_ s: String) -> Text { Text(s).foregroundStyle(.secondary) }

    /// Board, then list: Todoist-style pills that open menus. A #board or /list in the text overrides them.
    private func destination(_ r: QuickAddParser.Result, _ options: [QuickAddState.Option]) -> some View {
        let board = options.first { $0.key == state.boardKey }
        let lists = state.details[state.boardKey]?.lists ?? []
        let list = lists.first { $0.id == state.listId }
        return HStack(spacing: 4) {
            Menu {
                Picker("Board", selection: $state.boardKey) {
                    ForEach(options) { o in
                        Text(app.accounts.count > 1 ? "\(o.board.name) · \(o.accountLabel)" : o.board.name).tag(o.key)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                DestinationPill(maxWidth: 190) {
                    BoardBackground(background: board?.board.background)
                        .frame(width: 16, height: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    if app.accounts.count > 1, let board {
                        Text("\(board.board.name) \(Text("· \(board.accountLabel)").foregroundStyle(.secondary))")
                    } else {
                        Text(board?.board.name ?? "Board")
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(r.boardKey != nil)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Menu {
                Picker("List", selection: $state.listId) {
                    ForEach(lists) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                DestinationPill {
                    Text(list?.name ?? (state.details[state.boardKey] == nil ? "List" : "No lists"))
                        .foregroundStyle(list == nil ? .secondary : .primary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(r.listId != nil || lists.isEmpty)
        }
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
        return TokenChip(text: t.display, icon: icon, color: color)
    }

    private func submit(open: Bool) {
        guard !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !state.busy else { return }
        Task {
            if await state.submit(open: open) { QuickAddController.shared.hide() }
        }
    }
}

/// The panel's surface: Liquid Glass on macOS 26 and later, a material before that. The window server draws the
/// panel's shadow around whatever isn't transparent, so the glass is clipped to its shape: its own soft shadow would
/// get a hard outline traced around it.
private struct PanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.5)), in: .rect(cornerRadius: 22))
                .clipShape(.rect(cornerRadius: 22))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: 14))
        }
    }
}

/// A board or list in the footer: a quiet capsule that brightens on hover.
private struct DestinationPill<Content: View>: View {
    var maxWidth: CGFloat = 130
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            content
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .frame(maxWidth: maxWidth)
        .background(Color.primary.opacity(hovering && enabled ? 0.1 : 0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .opacity(enabled ? 1 : 0.5)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}

/// One thing the parser understood, tinted by kind.
private struct TokenChip: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small)
            Text(text).lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.2)))
    }
}

/// A key drawn as a small rounded keycap, for shortcut hints.
private struct Keycap: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 18, height: 18)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

struct QuickAddHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick add syntax").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                row("#board", "Pick a board, or a list on it with **#board/list**. A prefix is enough.")
                row("/list", "Pick a list")
                row("@me", "Assign yourself, or anyone with **@name**")
                row("!label", "Add a label, by name or colour")
                row("tomorrow", "Set a due date: **today**, **fri 5pm**, **next week**, **in 3 days**, **jan 5**")
            }
            Divider()
            HStack(spacing: 14) {
                shortcut(["return"], "Add")
                shortcut(["command", "return"], "Add & Open")
                shortcut(["shift", "return"], "New line")
            }
            Text("Paste several lines to add one card per line. Only tokens that match something are used; everything else stays in the title.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }

    private func row(_ token: String, _ text: LocalizedStringKey) -> some View {
        GridRow {
            Text(token)
                .font(.callout.monospaced().weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(text).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcut(_ keys: [String], _ title: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { Keycap(symbol: $0) }
            Text(title).foregroundStyle(.secondary).padding(.leading, 3)
        }
    }
}
