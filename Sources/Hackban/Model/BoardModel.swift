import Foundation
import HackbanKit
import Observation

/// One open board: its data, live updates and every board-level mutation (applied optimistically).
@MainActor
@Observable
final class BoardModel {
    let app: AppModel
    let account: Account
    let boardId: String

    var board: Board?
    var loadError: String?
    var filters = CardFilters()
    var deleted = false
    /// The card sheet currently showing a card on this board, so live updates refresh it too.
    @ObservationIgnored weak var openCard: CardModel?

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var viewers = 0

    var api: HackbanAPI { account.api }
    var canEdit: Bool { board?.canEdit ?? false }

    init(app: AppModel, account: Account, boardId: String) {
        self.app = app
        self.account = account
        self.boardId = boardId
    }

    // MARK: loading & live updates

    func load() async {
        do {
            board = try await api.board(boardId)
            loadError = nil
        } catch {
            if let e = error as? HackbanError, case .server(let code, _, _) = e, code == "NOT_FOUND" || code == "FORBIDDEN" { deleted = true }
            account.handle(error)
            loadError = error.localizedDescription
        }
    }

    /// Called by each view showing the board; the stream runs while at least one is visible.
    func appear() {
        viewers += 1
        if board == nil { Task { await load() } }
        guard liveTask == nil else { return }
        let client = account.client
        let id = boardId
        liveTask = Task { [weak self] in
            for await event in client.boardEvents(boardId: id) {
                guard let self else { return }
                if let event {
                    if event.origin == client.clientId { continue }
                    if event.kind == "deleted" { self.deleted = true }
                    if let cardId = event.cardId, self.openCard?.cardId == cardId { self.openCard?.scheduleReload() }
                }
                self.scheduleReload()
            }
        }
    }

    func disappear() {
        viewers -= 1
        if viewers <= 0 {
            viewers = 0
            liveTask?.cancel()
            liveTask = nil
        }
    }

    func scheduleReload(after ms: UInt64 = 250) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    /// Apply a change locally now, send it, and reload from the server if it fails.
    func mutate(reload: Bool = false, _ local: (inout Board) -> Void = { _ in }, _ remote: @escaping () async throws -> Void) {
        if var b = board {
            local(&b)
            board = b
        }
        Task {
            do {
                try await remote()
                if reload { scheduleReload(after: 50) }
            } catch {
                account.handle(error)
                app.flash(error.localizedDescription)
                await load()
            }
        }
    }

    // MARK: lookups

    func card(_ id: String) -> Card? {
        guard let b = board, let (li, ci) = b.list(containing: id) else { return nil }
        return b.lists[li].openCards[ci]
    }

    func list(_ id: String) -> BoardList? { board?.lists.first { $0.id == id } }

    func visibleCards(in list: BoardList) -> [Card] {
        filters.isActive ? list.openCards.filter { filters.matches($0) } : list.openCards
    }

    private func editCard(_ id: String, in b: inout Board, _ f: (inout Card) -> Void) {
        guard let (li, ci) = b.list(containing: id) else { return }
        f(&b.lists[li].cards![ci])
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
        }) { [api, boardId] in try await api.updateBoard(boardId, patch) }
        if patch.name != nil || patch.closed != nil { Task { await account.refresh() } }
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
        mutate(reload: true) { [api, boardId] in _ = try await api.createList(boardId: boardId, name: name) }
    }

    func renameList(_ id: String, _ name: String) {
        mutate({ b in if let i = b.lists.firstIndex(where: { $0.id == id }) { b.lists[i].name = name } }) { [api] in try await api.updateList(id, name: name) }
    }

    func setListColor(_ id: String, _ color: String?) {
        mutate({ b in if let i = b.lists.firstIndex(where: { $0.id == id }) { b.lists[i].color = color } }) { [api] in try await api.updateList(id, color: .some(color)) }
    }

    func archiveList(_ id: String) {
        mutate({ $0.lists.removeAll { $0.id == id } }) { [api] in try await api.updateList(id, closed: true) }
    }

    /// Put list `id` right before `beforeId` (nil = at the end).
    func moveList(_ id: String, before beforeId: String?) {
        guard let b = board, let from = b.lists.firstIndex(where: { $0.id == id }), id != beforeId else { return }
        var lists = b.lists
        let moving = lists.remove(at: from)
        let to = beforeId.flatMap { bid in lists.firstIndex { $0.id == bid } } ?? lists.count
        let afterId = to > 0 ? lists[to - 1].id : nil
        lists.insert(moving, at: to)
        mutate({ $0.lists = lists }) { [api] in try await api.moveList(id, afterId: afterId) }
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
        let sorted = sort.sorted(l.openCards)
        mutate({ b in if let i = b.lists.firstIndex(where: { $0.id == id }) { b.lists[i].cards = sorted } }) { [api] in
            try await api.sortCards(id, ids: sorted.map(\.id))
        }
    }

    func archiveAllCards(in id: String) {
        mutate({ b in if let i = b.lists.firstIndex(where: { $0.id == id }) { b.lists[i].cards = [] } }) { [api] in try await api.archiveAllCards(id) }
    }

    func deleteList(_ id: String) {
        mutate({ $0.lists.removeAll { $0.id == id } }) { [api] in try await api.deleteList(id) }
    }

    // MARK: cards

    func addCard(to listId: String, title: String, atTop: Bool = false) async -> Card? {
        do {
            let c = try await api.createCard(listId: listId, title: title, after: atTop ? .some(nil) : nil)
            var front = c
            front.labels = []
            front.members = []
            front.watching = false
            if var b = board, let i = b.lists.firstIndex(where: { $0.id == listId }) {
                if atTop { b.lists[i].cards = [front] + b.lists[i].openCards } else { b.lists[i].cards = b.lists[i].openCards + [front] }
                board = b
            }
            scheduleReload(after: 500)
            return c
        } catch {
            account.handle(error)
            app.flash(error.localizedDescription)
            return nil
        }
    }

    func updateCard(_ id: String, _ patch: HackbanAPI.CardPatch) {
        let completingRepeat = patch.dueComplete == true && card(id)?.recurrence != nil
        mutate(reload: completingRepeat || patch.closed != nil, { b in
            if patch.closed == true {
                for i in b.lists.indices { b.lists[i].cards?.removeAll { $0.id == id } }
            } else {
                editCard(id, in: &b) { patch.apply(to: &$0) }
            }
        }) { [api] in try await api.updateCard(id, patch) }
        openCard?.applyLocal(patch)
    }

    /// Move card `id` into `listId`, right before `beforeId` (nil = at the end).
    func moveCard(_ id: String, to listId: String, before beforeId: String?) {
        guard var b = board, let (li, ci) = b.list(containing: id), id != beforeId,
              let ti = b.lists.firstIndex(where: { $0.id == listId }) else { return }
        var card = b.lists[li].cards!.remove(at: ci)
        card.listId = listId
        var target = b.lists[ti].openCards
        let at = beforeId.flatMap { bid in target.firstIndex { $0.id == bid } } ?? target.count
        let afterId = at > 0 ? target[at - 1].id : nil
        target.insert(card, at: at)
        b.lists[ti].cards = target
        mutate({ $0 = b }) { [api] in try await api.moveCard(id, listId: listId, afterId: afterId) }
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
        mutate({ b in
            editCard(id, in: &b) { c in
                if on { c.labels = (c.labels ?? []) + [CardLabel(cardId: id, labelId: label.id, label: label)] }
                else { c.labels?.removeAll { $0.labelId == label.id } }
            }
        }) { [api] in try await api.toggleLabel(card: id, label: label.id, on: on) }
        openCard?.scheduleReload()
    }

    func toggleMember(card id: String, user: User) {
        guard let c = card(id) else { return }
        let on = !c.memberIds.contains(user.id)
        mutate({ b in
            editCard(id, in: &b) { c in
                if on { c.members = (c.members ?? []) + [CardMember(cardId: id, userId: user.id, user: user)] }
                else { c.members?.removeAll { $0.userId == user.id } }
            }
        }) { [api] in try await api.toggleMember(card: id, user: user.id, on: on) }
        openCard?.scheduleReload()
    }

    func toggleWatch(card id: String) {
        let on = !(card(id)?.watching ?? false)
        mutate({ b in editCard(id, in: &b) { $0.watching = on } }) { [api] in try await api.watchCard(id, on) }
    }

    func deleteCard(_ id: String) {
        mutate({ b in for i in b.lists.indices { b.lists[i].cards?.removeAll { $0.id == id } } }) { [api] in try await api.deleteCard(id) }
    }

    func copyCard(_ id: String, title: String, listId: String, keep: HackbanAPI.CopyKeep) {
        mutate(reload: true) { [api] in _ = try await api.copyCard(id, title: title, listId: listId, keep: keep) }
    }

    // MARK: labels

    func createLabel(name: String, color: String?) async -> Label? {
        do {
            let l = try await api.createLabel(boardId: boardId, name: name, color: color)
            board?.labels.append(l)
            return l
        } catch {
            app.flash(error.localizedDescription)
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
