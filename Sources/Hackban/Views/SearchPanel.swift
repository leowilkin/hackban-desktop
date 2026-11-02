import AppKit
import HackbanKit
import Observation
import SwiftUI

/// Search as a floating panel, like quick add: boards match as you type, and cards come from every server's search.
@MainActor
final class SearchController: NSObject, NSWindowDelegate {
    static let shared = SearchController()
    private var panel: FloatingPanel?
    private let state = SearchState()

    func show() {
        let p = panel ?? makePanel()
        panel = p
        state.query = ""
        state.selected = 0
        p.present()
        state.focusToken += 1
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel.make(width: 620, height: 440, delegate: self, content: SearchPanelView(state: state).environment(AppModel.shared))
        p.onCancel = { SearchController.shared.hide() }
        return p
    }

    /// Clicking anywhere else dismisses it, like Spotlight.
    func windowDidResignKey(_ notification: Notification) { hide() }
}

@MainActor
@Observable
final class SearchState {
    var query = ""
    var selected = 0
    var cards: [(account: Account, card: Card)] = []
    var searching = false
    var focusToken = 0
}

private struct SearchItem: Identifiable {
    enum Kind {
        case board(BoardSummary, workspace: String)
        case card(Card)
    }

    let account: Account
    let kind: Kind

    var id: String {
        switch kind {
        case .board(let b, _): return "board|\(account.id)|\(b.id)"
        case .card(let c): return "card|\(account.id)|\(c.id)"
        }
    }
}

private struct SearchPanelView: View {
    @Bindable var state: SearchState
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        let boards = boardItems, cards = state.cards.map { SearchItem(account: $0.account, kind: .card($0.card)) }
        let items = boards + cards
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Search boards and cards", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if items.indices.contains(state.selected) { open(items[state.selected]) } }
                    .onKeyPress(.downArrow) { state.selected = min(state.selected + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { state.selected = max(state.selected - 1, 0); return .handled }
                if state.searching { ProgressView().controlSize(.small) }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !boards.isEmpty { heading(state.query.isEmpty ? "Recent boards" : "Boards") }
                        ForEach(Array(boards.enumerated()), id: \.element.id) { pair in row(pair.element, index: pair.offset) }
                        if !cards.isEmpty { heading("Cards") }
                        ForEach(Array(cards.enumerated()), id: \.element.id) { pair in row(pair.element, index: boards.count + pair.offset) }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: state.selected) { _, s in if items.indices.contains(s) { proxy.scrollTo(items[s].id) } }
            }
            .overlay {
                if items.isEmpty && !state.searching {
                    Text(state.query.count >= 2 ? "Nothing found for “\(state.query)”." : "Type to search boards and cards.").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 14) {
                Text("↑↓ move")
                Text("↩ open")
                Text("⎋ close")
                Spacer()
                if app.visibleAccounts.count > 1 { Text("Searching every server") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 620, height: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: state.query) { _, _ in state.selected = 0 }
        .onChange(of: state.focusToken) { _, _ in focused = true }
        .onAppear { focused = true }
        .task(id: state.query) { await search() }
    }

    /// Boards on every account: the recently viewed ones until you type, then matches by name or workspace.
    private var boardItems: [SearchItem] {
        let all = app.visibleAccounts.flatMap { a in a.allBoards.map { SearchItem(account: a, kind: .board($0.board, workspace: $0.workspace)) } }
        let q = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            let recent = app.visibleAccounts.flatMap { a in a.recent.compactMap { r in all.first { $0.id == "board|\(a.id)|\(r.id)" } } }
            return recent.isEmpty ? all : recent
        }
        func name(_ i: SearchItem) -> (String, String) {
            if case .board(let b, let w) = i.kind { return (b.name.lowercased(), w.lowercased()) }
            return ("", "")
        }
        return all.filter { name($0).0.contains(q) || name($0).1.contains(q) }
            .sorted { (name($0).0.hasPrefix(q) ? 0 : 1) < (name($1).0.hasPrefix(q) ? 0 : 1) }
            .prefix(8)
            .map { $0 }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func row(_ item: SearchItem, index: Int) -> some View {
        HStack(spacing: 10) {
            switch item.kind {
            case .board(let b, let workspace):
                BoardBackground(background: b.background).frame(width: 22, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
                Text(b.name).lineLimit(1)
                Text(workspace).foregroundStyle(.secondary).lineLimit(1)
            case .card(let c):
                Image(systemName: c.dueComplete ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary).frame(width: 22)
                Text(c.title).lineLimit(1)
                Text([c.list?.board?.name, c.list?.name].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            AccountTag(account: item.account)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(index == state.selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
        .id(item.id)
    }

    private func open(_ item: SearchItem) {
        SearchController.shared.hide()
        NSApp.activate()
        switch item.kind {
        case .board(let b, _): app.open(board: b.id, in: item.account)
        case .card(let c): app.open(card: c.id, in: item.account, board: c.list?.board?.id)
        }
    }

    private func search() async {
        let q = state.query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            state.cards = []
            state.searching = false
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        state.searching = true
        var out: [(account: Account, card: Card)] = []
        for a in app.visibleAccounts where !a.signedOut {
            if let r = try? await a.api.search(q) { out += r.cards.map { (a, $0) } }
        }
        guard !Task.isCancelled else { return }
        state.cards = out
        state.searching = false
    }
}
