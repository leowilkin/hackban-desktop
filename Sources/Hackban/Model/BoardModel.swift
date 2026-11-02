import Foundation
import HackbanKit
import Observation

/// One open board: live updates and every board-level change.
///
/// The board itself comes from the account's `SyncEngine`: the last server snapshot with changes still
/// waiting to sync on top. Changes that work offline are queued there (`perform`). The rest need a
/// connection: they're applied to the snapshot at once and sent, and the board is refetched if they fail.
@MainActor
@Observable
final class BoardModel {
    let app: AppModel
    let account: Account
    let boardId: String

    var loadError: String?
    var filters = CardFilters()
    var deleted = false
    /// The card sheet currently showing a card on this board, so live updates refresh it too.
    @ObservationIgnored weak var openCard: CardModel?

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var viewers = 0

    var api: HackbanAPI { account.api }
    var sync: SyncEngine { account.sync }
    var board: Board? { sync.boards[boardId] }
    var canEdit: Bool { board?.canEdit ?? false }

    init(app: AppModel, account: Account, boardId: String) {
        self.app = app
        self.account = account
        self.boardId = boardId
    }

    // MARK: loading & live updates

    static let notDownloaded = "This board hasn't been downloaded yet. It'll load when you're back online."

    func load() async {
        sync.loadCachedBoard(boardId)
        guard !sync.isOffline else {
            if board == nil { loadError = Self.notDownloaded }
            return
        }
        let started = Date()
        do {
            sync.store(board: try await api.board(boardId), fetchStarted: started)
            loadError = nil
        } catch {
            if let e = error as? HackbanError, case .server(let code, _, _) = e, code == "NOT_FOUND" || code == "FORBIDDEN" { deleted = true }
            account.handle(error)
            loadError = sync.isOffline ? (board == nil ? Self.notDownloaded : nil) : error.localizedDescription
        }
    }

    /// Called by each view showing the board; the stream runs while at least one is visible and the
    /// server can be reached.
    func appear() {
        viewers += 1
        sync.loadCachedBoard(boardId)
        if board == nil || sync.isOffline { Task { await load() } }
        startLive()
    }

    func disappear() {
        viewers -= 1
        if viewers <= 0 {
            viewers = 0
            stopLive()
        }
    }

    private func startLive() {
        guard liveTask == nil, viewers > 0, !sync.isOffline else { return }
        let client = account.client
        let id = boardId
        liveTask = Task { [weak self] in
            // Yields nil on every (re)connect, which refetches whatever was missed.
            for await event in client.boardEvents(boardId: id) {
                guard let self else { return }
                if let event {
                    if event.origin == client.clientId { continue }
                    if event.kind == "deleted" { self.deleted = true }
                    if let cardId = event.cardId, self.openCard?.id == cardId { self.openCard?.scheduleReload() }
                }
                self.scheduleReload()
            }
        }
    }

    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
    }

    /// Back online: reconnect live updates, which refetch the board as they connect.
    func reconnect() {
        stopLive()
        if viewers > 0 { startLive() }
    }

    func scheduleReload(after ms: UInt64 = 250) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    /// Queue a change that works offline.
    func perform(_ change: Change) { sync.perform(change, board: boardId) }

    /// A change that needs a connection: applied locally now, sent, and the board refetched if it fails.
    func mutate(reload: Bool = false, _ local: (inout Board) -> Void = { _ in }, _ remote: @escaping () async throws -> Void) {
        guard app.requireOnline(account) else { return }
        sync.editSnapshot(boardId, local)
        Task {
            do {
                try await remote()
                if reload { scheduleReload(after: 50) }
            } catch {
                account.handle(error)
                app.flash(app.message(for: error))
                await load()
            }
        }
    }

    // MARK: lookups

    func card(_ id: String) -> Card? {
        guard let b = board, let (li, ci) = b.list(containing: sync.resolve(id)) else { return nil }
        return b.lists[li].openCards[ci]
    }

    func list(_ id: String) -> BoardList? { board?.lists.first { $0.id == sync.resolve(id) } }

    func visibleCards(in list: BoardList) -> [Card] {
        filters.isActive ? list.openCards.filter { filters.matches($0) } : list.openCards
    }

    // MARK: board

    func updateBoard(_ patch: HackbanAPI.BoardPatch) {
        mutate({ b in
            if let v = patch.name { b.name = v }
            if let v = patch.description { b.description = v }
            if let v = patch.background { b.background = v }
            if let v = patch.bgImage { b.bgImage = v }
            if let v = patch.visibility { b.visibility = v }
            if let v = patch.closed { b.closed = v }
        }) { [api, boardId, account] in
            try await api.updateBoard(boardId, patch)
            if patch.name != nil || patch.closed != nil { await account.refresh() }
        }
    }

    func toggleStar() {
        let on = !(board?.starred ?? false)
        mutate({ $0.starred = on }) { [api, boardId, account] in
            try await api.starBoard(boardId, on)
            await account.refresh()
        }
    }

    // MARK: lists

    func addList(_ name: String) {
        perform(.createList(id: TempID.make(), name: name))
    }

    func renameList(_ id: String, _ name: String) {
        perform(.updateList(id: id, patch: .init(name: name)))
    }

    func setListColor(_ id: String, _ color: String?) {
        perform(.updateList(id: id, patch: .init(color: .some(color))))
    }

    func archiveList(_ id: String) {
        perform(.updateList(id: id, patch: .init(closed: true)))
    }

    /// Put list `id` right before `beforeId` (nil = at the end).
    func moveList(_ id: String, before beforeId: String?) {
        guard let b = board, b.lists.contains(where: { $0.id == id }), id != beforeId else { return }
        let others = b.lists.map(\.id).filter { $0 != id }
        let to = beforeId.flatMap { others.firstIndex(of: $0) } ?? others.count
        perform(.moveList(id: id, above: Anchors.above(to, in: others)))
    }

    func moveListToBoard(_ id: String, board target: String) {
        mutate(reload: true, { $0.lists.removeAll { $0.id == id } }) { [api] in try await api.moveList(id, afterId: nil, toBoard: target) }
    }

    func copyList(_ id: String, name: String) {
        mutate(reload: true) { [api] in try await api.copyList(id, name: name) }
    }

    func moveAllCards(from id: String, to target: String) {
        mutate(reload: true, { b in
            guard let fi = b.lists.firstIndex(where: { $0.id == id }), let ti = b.lists.firstIndex(where: { $0.id == target }) else { return }
            let moving = b.lists[fi].openCards.map { c -> Card in var c = c; c.listId = target; return c }
            b.lists[fi].cards = []
            b.lists[ti].cards = b.lists[ti].openCards + moving
        }) { [api] in try await api.moveAllCards(id, to: target) }
    }

    func sortList(_ id: String, by sort: CardSort) {
        guard let l = list(id) else { return }
        perform(.sortList(id: l.id, cardIds: sort.sorted(l.openCards).map(\.id)))
    }

    func archiveAllCards(in id: String) {
        mutate({ b in if let i = b.lists.firstIndex(where: { $0.id == id }) { b.lists[i].cards = [] } }) { [api] in try await api.archiveAllCards(id) }
    }

    func deleteList(_ id: String) {
        mutate({ $0.lists.removeAll { $0.id == id } }) { [api] in try await api.deleteList(id) }
    }

    // MARK: cards

    /// Adds a card (straight away, even offline) and returns its id, temporary until it syncs.
    @discardableResult
    func addCard(to listId: String, title: String, atTop: Bool = false) -> String {
        let id = TempID.make()
        perform(.createCard(id: id, listId: listId, title: title, atTop: atTop))
        return id
    }

    func updateCard(_ id: String, _ patch: HackbanAPI.CardPatch) {
        sync.updateCard(id, patch, board: boardId)
    }

    /// Move card `id` into `listId`, right before `beforeId` (nil = at the end).
    func moveCard(_ id: String, to listId: String, before beforeId: String?) {
        guard let b = board, b.list(containing: id) != nil, id != beforeId, let target = b.lists.first(where: { $0.id == listId }) else { return }
        let others = target.openCards.map(\.id).filter { $0 != id }
        let at = beforeId.flatMap { others.firstIndex(of: $0) } ?? others.count
        perform(.moveCard(id: id, listId: listId, above: Anchors.above(at, in: others)))
    }

    func moveCard(_ id: String, toList listId: String, onBoard boardId: String, position: Int?) {
        if boardId == self.boardId, let l = list(listId) {
            let others = l.openCards.filter { $0.id != id }
            let before = position.flatMap { $0 < others.count ? others[$0].id : nil }
            moveCard(id, to: listId, before: before)
            return
        }
        mutate(reload: true, { b in for i in b.lists.indices { b.lists[i].cards?.removeAll { $0.id == id } } }) { [api] in
            // Position on another board: the server takes "after"; resolve against that board's list.
            var afterId: String?
            if let position, position > 0 {
                let other = try await api.board(boardId)
                let cards = other.lists.first { $0.id == listId }?.openCards ?? []
                afterId = cards[min(position, cards.count) - 1].id
            } else if position == nil {
                let other = try await api.board(boardId)
                afterId = other.lists.first { $0.id == listId }?.openCards.last?.id
            }
            try await api.moveCard(id, listId: listId, afterId: afterId)
        }
    }

    func toggleLabel(card id: String, label: Label) {
        guard let c = card(id) else { return }
        let on = !c.labelIds.contains(label.id)
        perform(.setLabel(cardId: c.id, label: label, on: on, was: !on))
    }

    func toggleMember(card id: String, user: User) {
        guard let c = card(id) else { return }
        let on = !c.memberIds.contains(user.id)
        perform(.setMember(cardId: c.id, user: user, on: on, was: !on))
    }

    func toggleWatch(card id: String) {
        guard let c = card(id) else { return }
        let on = !(c.watching ?? false)
        perform(.watch(cardId: c.id, on: on, was: !on))
    }

    func deleteCard(_ id: String) {
        perform(.deleteCard(id: id))
    }

    func copyCard(_ id: String, title: String, listId: String, keep: HackbanAPI.CopyKeep) {
        mutate(reload: true) { [api] in _ = try await api.copyCard(id, title: title, listId: listId, keep: keep) }
    }

    // MARK: labels

    func createLabel(name: String, color: String?) async -> Label? {
        guard app.requireOnline(account) else { return nil }
        do {
            let l = try await api.createLabel(boardId: boardId, name: name, color: color)
            sync.editSnapshot(boardId) { $0.labels.append(l) }
            return l
        } catch {
            account.handle(error)
            app.flash(app.message(for: error))
            return nil
        }
    }

    func updateLabel(_ id: String, name: String, color: String?) {
        mutate(reload: true, { b in
            if let i = b.labels.firstIndex(where: { $0.id == id }) { b.labels[i].name = name; b.labels[i].color = color }
        }) { [api] in try await api.updateLabel(id, name: name, color: color) }
    }

    func deleteLabel(_ id: String) {
        mutate({ b in
            b.labels.removeAll { $0.id == id }
            for li in b.lists.indices { for ci in b.lists[li].openCards.indices { b.lists[li].cards![ci].labels?.removeAll { $0.labelId == id } } }
        }) { [api] in try await api.deleteLabel(id) }
    }

    // MARK: members

    func addMember(userId: String? = nil, email: String? = nil, role: String = "normal") {
        mutate(reload: true) { [api, boardId] in try await api.addBoardMember(boardId, userId: userId, email: email, role: role) }
    }

    func removeMember(_ userId: String) {
        mutate(reload: true, { $0.members.removeAll { $0.userId == userId } }) { [api, boardId] in try await api.removeBoardMember(boardId, userId: userId) }
    }
}
