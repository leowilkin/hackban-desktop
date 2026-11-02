import Foundation

/// Conflict rules for an edit that waited while someone else may have changed the same card.
///
/// Each field is checked against `base`, its value when you made the edit:
/// - the server still has the base value, or already has yours: no conflict (and nothing to send if it's yours)
/// - someone else changed the title or description: theirs stays and yours is kept as a conflict, since
///   overwriting text loses someone's writing
/// - any other field: yours wins. It's the later, deliberate change and cheap to undo.
public enum ConflictCheck {
    public static func cardUpdate(patch: HackbanAPI.CardPatch, base: HackbanAPI.CardPatch, server: Card?) -> (send: HackbanAPI.CardPatch, conflicts: [FieldConflict]) {
        guard let s = server else { return (patch, []) }
        var send = patch.removingFields(equalTo: patch.base(from: s))
        var conflicts: [FieldConflict] = []
        if let mine = send.title, let was = base.title, s.title != was {
            conflicts.append(FieldConflict(field: "title", theirs: s.title, mine: mine))
            send.title = nil
        }
        if let mine = send.description, let was = base.description, s.description != was {
            conflicts.append(FieldConflict(field: "description", theirs: s.description, mine: mine))
            send.description = nil
        }
        // Completing a repeating card moves its due date on. If it's already moved, this completion (or
        // someone else's) has happened: sending it again would skip an occurrence.
        if send.dueComplete == true, s.recurrence != nil, let was = base.due, s.due != was {
            send.dueComplete = nil
        }
        return (send, conflicts)
    }
}

/// A request made after the change itself (fetching its new id) or while looking for it failed. The
/// change may well have happened, so a create keeps its "sent" mark and is looked for next time.
public struct AfterChangeError: LocalizedError {
    public let underlying: Error
    public var errorDescription: String? { underlying.localizedDescription }
}

/// Sends one queued change to the server.
public struct Replayer: Sendable {
    public let api: HackbanAPI
    /// The signed-in user's id, to recognise a comment of yours that already arrived.
    public let me: String?

    public init(api: HackbanAPI, me: String?) {
        self.api = api
        self.me = me
    }

    public enum Outcome: Equatable, Sendable {
        /// `createdId`: the server's id for what a create made (nil if it couldn't be found afterwards).
        case done(createdId: String?)
        /// The non-clashing part (if any) was sent; `kept` is the part someone else changed first.
        case conflict(sent: Change?, kept: Change, conflicts: [FieldConflict])
        /// The server can't take it any more (the card was deleted, the list archived…).
        case rejected(String)
    }

    // MARK: finding creates that may already exist

    /// Things on the server that look like what `change` creates, oldest first. `existing` (captured
    /// before a create is sent) and every id already handed out are subtracted before adopting one.
    /// Nil when the needed snapshot is missing.
    public func lookalikes(_ change: Change, board: Board?, card: Card?) -> [String]? {
        switch change {
        case .createCard(_, let listId, let title, _):
            guard let b = board else { return nil }
            return b.lists.first { $0.id == listId }?.openCards.filter { $0.title == title }.map(\.id) ?? []
        case .createList(_, let name):
            guard let b = board else { return nil }
            return b.lists.filter { $0.name == name }.map(\.id)
        case .addChecklist(_, let cardId, let name):
            guard let c = card, c.id == cardId else { return nil }
            return (c.checklists ?? []).filter { $0.name == name }.map(\.id)
        case .addCheckItem(_, let cardId, let checklistId, let name):
            guard let c = card, c.id == cardId else { return nil }
            return (c.checklists ?? []).first { $0.id == checklistId }?.items.filter { $0.name == name }.map(\.id) ?? []
        case .addComment(_, let cardId, let text, _, _):
            guard let c = card, c.id == cardId else { return nil }
            // Newest first on the server.
            return (c.comments ?? []).filter { $0.text == text && (me == nil || $0.authorId == me) }.map(\.id).reversed()
        case .addLink(_, let cardId, let url, _):
            guard let c = card, c.id == cardId else { return nil }
            return (c.attachments ?? []).filter { $0.url == url }.map(\.id).reversed()
        default:
            return nil
        }
    }

    /// The newest look-alike that isn't one of `exclude`.
    public func adopt(_ change: Change, board: Board?, card: Card?, exclude: Set<String>) -> String? {
        lookalikes(change, board: board, card: card)?.last { !exclude.contains($0) }
    }

    /// Fetches what the create would have landed in and looks for it.
    private func find(_ op: PendingOp, mapped: Set<String>) async throws -> String? {
        let exclude = mapped.union(op.existing ?? [])
        do {
            switch op.change {
            case .createCard, .createList:
                return adopt(op.change, board: try await api.board(op.boardId), card: nil, exclude: exclude)
            default:
                guard let cardId = op.change.cardId else { return nil }
                return adopt(op.change, board: nil, card: try await api.card(cardId), exclude: exclude)
            }
        } catch {
            throw AfterChangeError(underlying: error)
        }
    }

    /// After a create that doesn't return its row: fetch the card and pick the new thing out.
    private func findAfterCreate(_ op: PendingOp, cardId: String, mapped: Set<String>) async throws -> String? {
        do {
            return adopt(op.change, board: nil, card: try await api.card(cardId), exclude: mapped.union(op.existing ?? []))
        } catch {
            throw AfterChangeError(underlying: error)
        }
    }

    // MARK: sending

    /// Sends `op`, whose change must already have server ids. `board` and `card` are the latest server
    /// snapshots, for conflict checks and drop spots. `inDoubt`: an earlier try may have reached the
    /// server, so a create is looked for first. `mapped`: every server id handed out for things made
    /// offline, which a lookup must never adopt.
    public func run(_ op: PendingOp, inDoubt: Bool, board: Board?, card: Card?, mapped: Set<String>) async throws -> Outcome {
        do {
            return try await send(op, inDoubt: inDoubt, board: board, card: card, mapped: mapped)
        } catch let e as AfterChangeError {
            if case .server(let code, _, _)? = e.underlying as? HackbanError, code == "NOT_FOUND" { return .rejected(gone(op.change)) }
            throw e
        } catch let e as HackbanError {
            guard case .server(let code, let status, _) = e else { throw e }
            let change = op.change
            if code == "NOT_FOUND" {
                return change.isDelete ? .done(createdId: nil) : .rejected(gone(change))
            }
            if code == "FORBIDDEN" { return .rejected("You can't change this any more. You may have lost access to the board.") }
            // A missing checklist, item, comment or attachment comes back as a 500. Check before retrying.
            if status == 500, let cardId = change.cardId, change.isOnCardDetail {
                let fresh: Card
                do { fresh = try await api.card(cardId) } catch HackbanError.server(let c, _, _) where c == "NOT_FOUND" {
                    return change.isDelete ? .done(createdId: nil) : .rejected(gone(.deleteCard(id: cardId)))
                }
                if !change.detailReferences.allSatisfy(fresh.contains) {
                    return change.isDelete ? .done(createdId: nil) : .rejected(gone(change))
                }
            }
            throw e
        }
    }

    private func gone(_ change: Change) -> String {
        switch change {
        case .createCard, .createList, .updateList, .moveList, .sortList: return "The list was deleted or archived by someone else."
        case .addChecklist, .addComment, .addLink, .updateCard, .moveCard, .setLabel, .setMember, .watch, .deleteCard:
            return "The card was deleted, or you no longer have access to it."
        case .renameChecklist, .deleteChecklist, .addCheckItem: return "The checklist was deleted by someone else."
        case .updateCheckItem, .moveCheckItem, .deleteCheckItem: return "The checklist item was deleted by someone else."
        case .editComment, .deleteComment: return "The comment was deleted."
        case .renameAttachment, .deleteAttachment: return "The attachment was deleted by someone else."
        }
    }

    private func send(_ op: PendingOp, inDoubt: Bool, board: Board?, card: Card?, mapped: Set<String>) async throws -> Outcome {
        if inDoubt, op.change.created != nil, let found = try await find(op, mapped: mapped) {
            return .done(createdId: found)
        }
        let card = card?.id == op.change.cardId ? card : nil
        switch op.change {
        case .createCard(_, let listId, let title, let atTop):
            let c = try await api.createCard(listId: listId, title: title, after: atTop ? .some(nil) : nil)
            return .done(createdId: c.id)

        case .updateCard(let id, let patch, let base):
            let server = board.flatMap { b in b.list(containing: id).map { b.lists[$0.index].openCards[$0.cardIndex] } } ?? card
            let (send, conflicts) = ConflictCheck.cardUpdate(patch: patch, base: base, server: server)
            if !send.isEmpty { try await api.updateCard(id, send) }
            guard !conflicts.isEmpty else { return .done(createdId: nil) }
            let fields = Set(conflicts.map(\.field))
            return .conflict(
                sent: send.isEmpty ? nil : .updateCard(id: id, patch: send, base: base),
                kept: .updateCard(id: id, patch: patch.only(fields), base: base.only(fields)),
                conflicts: conflicts
            )

        case .moveCard(let id, let listId, let above):
            var after = above.first { !TempID.isTemp($0) }
            if let b = board {
                guard let target = b.lists.first(where: { $0.id == listId }) else {
                    return .rejected("The list it was moved to was deleted or archived by someone else.")
                }
                after = Anchors.after(above, in: target.openCards.map(\.id).filter { $0 != id })
            }
            try await api.moveCard(id, listId: listId, afterId: after)

        case .setLabel(let cardId, let label, let on, _): try await api.toggleLabel(card: cardId, label: label.id, on: on)
        case .setMember(let cardId, let user, let on, _): try await api.toggleMember(card: cardId, user: user.id, on: on)
        case .watch(let cardId, let on, _): try await api.watchCard(cardId, on)
        case .deleteCard(let id): try await api.deleteCard(id)

        case .addChecklist(_, let cardId, let name):
            return .done(createdId: try await api.addChecklist(card: cardId, name: name).id)
        case .renameChecklist(let id, _, let name): try await api.renameChecklist(id, name: name)
        case .deleteChecklist(let id, _): try await api.deleteChecklist(id)

        case .addCheckItem(_, let cardId, let checklistId, let name):
            // The server doesn't return the new item: it's the newest one with this name.
            try await api.addCheckItem(checklist: checklistId, name: name)
            return .done(createdId: try await findAfterCreate(op, cardId: cardId, mapped: mapped))
        case .updateCheckItem(let id, _, let p, _):
            try await api.updateCheckItem(id, name: p.name, complete: p.complete, due: p.due, memberId: p.member.map { $0?.id })
        case .moveCheckItem(let id, _, let checklistId, let above):
            var after = above.first { !TempID.isTemp($0) }
            if let items = card?.checklists?.first(where: { $0.id == checklistId })?.items {
                after = Anchors.after(above, in: items.map(\.id).filter { $0 != id })
            }
            try await api.moveCheckItem(id, checklist: checklistId, afterId: after)
        case .deleteCheckItem(let id, _): try await api.deleteCheckItem(id)

        case .addComment(_, let cardId, let text, _, _):
            return .done(createdId: try await api.addComment(card: cardId, text: text).id)
        case .editComment(let id, _, let text): try await api.editComment(id, text: text)
        case .deleteComment(let id, _): try await api.deleteComment(id)

        case .addLink(_, let cardId, let url, let name):
            // Like check items, links come back without an id.
            try await api.addLink(card: cardId, url: url, name: name)
            return .done(createdId: try await findAfterCreate(op, cardId: cardId, mapped: mapped))
        case .renameAttachment(let id, _, let name): try await api.renameAttachment(id, name: name)
        case .deleteAttachment(let id, _): try await api.deleteAttachment(id)

        case .createList(_, let name):
            return .done(createdId: try await api.createList(boardId: op.boardId, name: name).id)
        case .updateList(let id, let p): try await api.updateList(id, name: p.name, color: p.color, closed: p.closed)
        case .moveList(let id, let above):
            var after = above.first { !TempID.isTemp($0) }
            if let b = board { after = Anchors.after(above, in: b.lists.map(\.id).filter { $0 != id }) }
            try await api.moveList(id, afterId: after)
        case .sortList(let id, let ids):
            try await api.sortCards(id, ids: ids.filter { !TempID.isTemp($0) })
        }
        return .done(createdId: nil)
    }
}

extension Change {
    /// Changes to a card's checklists, comments or attachments (whose rows the server reports missing as a 500).
    var isOnCardDetail: Bool {
        switch self {
        case .renameChecklist, .deleteChecklist, .addCheckItem, .updateCheckItem, .moveCheckItem, .deleteCheckItem,
             .editComment, .deleteComment, .renameAttachment, .deleteAttachment:
            return true
        default: return false
        }
    }

    /// The checklists, items, comments or attachments it needs.
    var detailReferences: [String] {
        switch self {
        case .addCheckItem(_, _, let cl, _): return [cl]
        case .moveCheckItem(let id, _, let cl, _): return [id, cl]
        default: return isOnCardDetail ? [subject] : []
        }
    }
}

extension Card {
    /// Whether one of its checklists, check items, comments or attachments has this id.
    func contains(_ id: String) -> Bool {
        (checklists ?? []).contains { $0.id == id || $0.items.contains { $0.id == id } }
            || (comments ?? []).contains { $0.id == id }
            || (attachments ?? []).contains { $0.id == id }
    }
}
