import Foundation

/// The changes waiting to reach one account's server, in the order they were made, plus the ones that
/// failed and the server ids handed out for things made offline.
///
/// Changes go out strictly in order, one at a time. Adding a change folds it into an earlier one where
/// the result is the same (typing a description offline is one update, not forty), and deleting
/// something that never reached the server drops its whole history. Nothing is ever folded into a
/// change that's being sent or may already have arrived.
public struct OfflineQueue: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var version = OfflineQueue.formatVersion
    /// The profile id the changes were made as. They're only sent as that user.
    public var userId: String?
    public private(set) var pending: [PendingOp] = []
    public private(set) var failed: [FailedOp] = []
    /// Temp id → server id, for everything made offline that has reached the server.
    public private(set) var ids: [String: String] = [:]
    /// The op being sent right now. Not saved: after a relaunch it's simply first in line again.
    public var sending: String?

    enum CodingKeys: String, CodingKey { case version, userId, pending, failed, ids }

    public init(userId: String? = nil) { self.userId = userId }

    public var isEmpty: Bool { pending.isEmpty && failed.isEmpty }
    public var next: PendingOp? { pending.first }
    public var boardIds: Set<String> { Set(pending.map(\.boardId)) }

    public func resolve(_ id: String) -> String { ids[id] ?? id }
    public func resolved(_ change: Change) -> Change { change.mapIds(resolve) }

    /// Temp ids `change` needs that haven't reached the server (its own new id doesn't count).
    public func unresolved(_ change: Change) -> [String] {
        resolved(change).references.filter(TempID.isTemp)
    }

    private func isLocked(_ op: PendingOp) -> Bool { op.id == sending || op.sentAt != nil }

    /// The not-yet-sent op that creates `id`.
    private func unsentCreate(of id: String) -> Int? {
        guard TempID.isTemp(id), ids[id] == nil else { return nil }
        return pending.firstIndex { $0.change.created == id && !isLocked($0) }
    }

    private func lastUnlocked(_ match: (Change) -> Bool) -> Int? {
        pending.lastIndex { !isLocked($0) && match($0.change) }
    }

    // MARK: adding

    public mutating func enqueue(_ new: PendingOp) {
        var op = new
        switch op.change {
        case .deleteCard(let id), .deleteChecklist(let id, _), .deleteCheckItem(let id, _), .deleteComment(let id, _), .deleteAttachment(let id, _),
             .untrackIssue(let id, _):
            // Made offline and never sent: as if it never happened.
            if unsentCreate(of: id) != nil {
                drop(from: id)
                return
            }

        case .updateCard(let id, var patch, var base):
            // A new card's title goes into its create.
            if let t = patch.title, let ci = unsentCreate(of: id), case .createCard(let cid, let l, _, let top) = pending[ci].change {
                pending[ci].change = .createCard(id: cid, listId: l, title: t, atTop: top)
                patch.title = nil
                base.title = nil
            }
            if let i = lastUnlocked({ if case .updateCard(id, _, _) = $0 { return true } else { return false } }),
               case .updateCard(_, let p0, let b0) = pending[i].change {
                // The earliest base wins: it's what the server had before any of these edits.
                let merged = p0.merged(with: patch).removingFields(equalTo: base.merged(with: b0))
                if merged.isEmpty { pending.remove(at: i) } else { pending[i].change = .updateCard(id: id, patch: merged, base: base.merged(with: b0)) }
                return
            }
            patch = patch.removingFields(equalTo: base)
            if patch.isEmpty { return }
            op.change = .updateCard(id: id, patch: patch, base: base)

        case .setLabel(let c, let label, let on, var was):
            if let i = lastUnlocked({ if case .setLabel(c, let l, _, _) = $0 { return l.id == label.id } else { return false } }),
               case .setLabel(_, _, _, let w) = pending[i].change {
                was = w
                pending.remove(at: i)
            }
            if on == was { return }
            op.change = .setLabel(cardId: c, label: label, on: on, was: was)

        case .setMember(let c, let user, let on, var was):
            if let i = lastUnlocked({ if case .setMember(c, let u, _, _) = $0 { return u.id == user.id } else { return false } }),
               case .setMember(_, _, _, let w) = pending[i].change {
                was = w
                pending.remove(at: i)
            }
            if on == was { return }
            op.change = .setMember(cardId: c, user: user, on: on, was: was)

        case .watch(let c, let on, var was):
            if let i = lastUnlocked({ if case .watch(c, _, _) = $0 { return true } else { return false } }), case .watch(_, _, let w) = pending[i].change {
                was = w
                pending.remove(at: i)
            }
            if on == was { return }
            op.change = .watch(cardId: c, on: on, was: was)

        case .updateCheckItem(let id, let c, var patch, var base):
            if let n = patch.name, let ci = unsentCreate(of: id), case .addCheckItem(let iid, let cid, let cl, _) = pending[ci].change {
                pending[ci].change = .addCheckItem(id: iid, cardId: cid, checklistId: cl, name: n)
                patch.name = nil
                base.name = nil
            }
            if let i = lastUnlocked({ if case .updateCheckItem(id, _, _, _) = $0 { return true } else { return false } }),
               case .updateCheckItem(_, _, let p0, let b0) = pending[i].change {
                let mergedBase = base.merged(with: b0)
                let merged = p0.merged(with: patch).removingFields(equalTo: mergedBase)
                if merged.isEmpty { pending.remove(at: i) } else { pending[i].change = .updateCheckItem(id: id, cardId: c, patch: merged, base: mergedBase) }
                return
            }
            patch = patch.removingFields(equalTo: base)
            if patch.isEmpty { return }
            op.change = .updateCheckItem(id: id, cardId: c, patch: patch, base: base)

        case .renameChecklist(let id, _, let name):
            if let ci = unsentCreate(of: id), case .addChecklist(let cid, let card, _) = pending[ci].change {
                pending[ci].change = .addChecklist(id: cid, cardId: card, name: name)
                return
            }
            if let i = lastUnlocked({ if case .renameChecklist(id, _, _) = $0 { return true } else { return false } }) { pending.remove(at: i) }

        case .editComment(let id, _, let text):
            if let ci = unsentCreate(of: id), case .addComment(let cid, let card, _, let author, let at) = pending[ci].change {
                pending[ci].change = .addComment(id: cid, cardId: card, text: text, author: author, at: at)
                return
            }
            if let i = lastUnlocked({ if case .editComment(id, _, _) = $0 { return true } else { return false } }) { pending.remove(at: i) }

        case .renameAttachment(let id, _, let name):
            if let ci = unsentCreate(of: id), case .addLink(let aid, let card, let url, _) = pending[ci].change {
                pending[ci].change = .addLink(id: aid, cardId: card, url: url, name: name)
                return
            }
            if let i = lastUnlocked({ if case .renameAttachment(id, _, _) = $0 { return true } else { return false } }) { pending.remove(at: i) }

        case .updateList(let id, var patch):
            if let n = patch.name, let ci = unsentCreate(of: id), case .createList(let lid, _) = pending[ci].change {
                pending[ci].change = .createList(id: lid, name: n)
                patch.name = nil
                if patch.isEmpty { return }
            }
            if let i = lastUnlocked({ if case .updateList(id, _) = $0 { return true } else { return false } }), case .updateList(_, let p0) = pending[i].change {
                pending[i].change = .updateList(id: id, patch: p0.merged(with: patch))
                return
            }
            op.change = .updateList(id: id, patch: patch)

        default:
            break
        }
        pending.append(op)
    }

    /// Removes the not-yet-sent create of `id` and everything that needs it, and forgets it as a drop spot.
    private mutating func drop(from id: String) {
        var gone: Set<String> = [id]
        pending = pending.filter { op in
            guard !isLocked(op), !gone.isDisjoint(with: op.change.references + [op.change.subject]) else { return true }
            if let c = op.change.created { gone.insert(c) }
            return false
        }
        for i in pending.indices where !isLocked(pending[i]) {
            pending[i].change = pending[i].change.withoutAnchors(gone)
        }
    }

    // MARK: sending

    /// A create is about to go out. `existing` = look-alikes already on the server, which a later lookup
    /// must not mistake for it.
    public mutating func markSent(_ opId: String, at date: Date = Date(), existing: [String]) {
        guard let i = pending.firstIndex(where: { $0.id == opId }) else { return }
        pending[i].sentAt = date
        pending[i].existing = existing
    }

    /// The create certainly never reached the server.
    public mutating func clearSent(_ opId: String) {
        guard let i = pending.firstIndex(where: { $0.id == opId }) else { return }
        pending[i].sentAt = nil
        pending[i].existing = nil
    }

    /// Counts a failed try that might work later and returns how many there have been.
    public mutating func noteAttempt(_ opId: String) -> Int {
        guard let i = pending.firstIndex(where: { $0.id == opId }) else { return 0 }
        pending[i].attempts += 1
        return pending[i].attempts
    }

    /// It reached the server. `createdId` is the server's id for what it made, if it made something.
    public mutating func complete(_ opId: String, createdId: String? = nil) {
        if sending == opId { sending = nil }
        guard let i = pending.firstIndex(where: { $0.id == opId }) else { return }
        let op = pending.remove(at: i)
        if let temp = op.change.created, TempID.isTemp(temp), let createdId { ids[temp] = createdId }
    }

    /// The server took part of it (if anything) and someone else got to the rest first: keep that part
    /// as a conflict.
    public mutating func conflict(_ opId: String, kept: Change, conflicts: [FieldConflict]) {
        if sending == opId { sending = nil }
        guard let i = pending.firstIndex(where: { $0.id == opId }) else { return }
        var op = pending.remove(at: i)
        op.change = kept
        failed.append(FailedOp(op: op, reason: "Someone else changed this while your edit was waiting to sync.", conflicts: conflicts))
    }

    /// It can't be sent. Anything that needs what it would have made fails with it.
    public mutating func fail(_ opId: String, reason: String) {
        if sending == opId { sending = nil }
        guard let i = pending.firstIndex(where: { $0.id == opId }) else { return }
        let op = pending.remove(at: i)
        failed.append(FailedOp(op: op, reason: reason))
        if let temp = op.change.created, ids[temp] == nil { failDependents(of: temp) }
    }

    /// Fails every waiting op that matches (except one being sent).
    public mutating func failAll(reason: String, where match: (PendingOp) -> Bool = { _ in true }) {
        let (out, keep) = pending.reduce(into: ([PendingOp](), [PendingOp]())) { acc, op in
            if op.id != sending, match(op) { acc.0.append(op) } else { acc.1.append(op) }
        }
        pending = keep
        failed += out.map { FailedOp(op: $0, reason: reason) }
    }

    private mutating func failDependents(of temp: String) {
        var gone: Set<String> = [temp]
        pending = pending.filter { op in
            guard op.id != sending, !gone.isDisjoint(with: op.change.references) else { return true }
            if let c = op.change.created { gone.insert(c) }
            failed.append(FailedOp(op: op, reason: "It needs something else that couldn't sync."))
            return false
        }
    }

    /// Failed ops that needed what `failedId` would have made (and what those would have made…).
    private func failedDependents(of failedId: String) -> [String] {
        guard let created = failed.first(where: { $0.id == failedId })?.op.change.created else { return [] }
        var gone: Set<String> = [created]
        var out: [String] = []
        for f in failed where f.id != failedId && !gone.isDisjoint(with: f.op.change.references) {
            out.append(f.id)
            if let c = f.op.change.created { gone.insert(c) }
        }
        return out
    }

    // MARK: failures

    /// Puts a failed op back in line (with whatever failed because of it). For a conflict, `useMine`
    /// sends your text over theirs.
    public mutating func retry(_ failedId: String, useMine: Bool = false) {
        guard failed.contains(where: { $0.id == failedId }) else { return }
        let ids = Set([failedId] + failedDependents(of: failedId))
        var back = failed.filter { ids.contains($0.id) }.sorted { $0.op.madeAt < $1.op.madeAt }
        failed.removeAll { ids.contains($0.id) }
        for i in back.indices {
            back[i].op.attempts = 0
            if back[i].id == failedId, useMine, let conflicts = back[i].conflicts, case .updateCard(let id, let patch, var base) = back[i].op.change {
                // Their text becomes the base, so yours goes through unless it changes again.
                for c in conflicts {
                    if c.field == "title" { base.title = c.theirs }
                    if c.field == "description" { base.description = c.theirs }
                }
                back[i].op.change = .updateCard(id: id, patch: patch, base: base)
            }
        }
        pending += back.map(\.op)
    }

    /// Forgets a failed op (and whatever failed because of it).
    public mutating func discard(_ failedId: String) {
        let ids = Set([failedId] + failedDependents(of: failedId))
        failed.removeAll { ids.contains($0.id) }
    }

    /// Forgets server ids nothing refers to any more.
    public mutating func pruneIds() {
        let used = Set((pending.map(\.change) + failed.map(\.op.change)).flatMap { $0.references + [$0.subject] + $0.anchors })
        ids = ids.filter { used.contains($0.key) }
    }
}

extension Change {
    /// The neighbours a move or sort mentions.
    var anchors: [String] {
        switch self {
        case .moveCard(_, _, let above), .moveList(_, let above), .moveCheckItem(_, _, _, let above): return above
        case .sortList(_, let ids): return ids
        default: return []
        }
    }

    func withoutAnchors(_ gone: Set<String>) -> Change {
        switch self {
        case .moveCard(let id, let l, let above): return .moveCard(id: id, listId: l, above: above.filter { !gone.contains($0) })
        case .moveList(let id, let above): return .moveList(id: id, above: above.filter { !gone.contains($0) })
        case .moveCheckItem(let id, let c, let cl, let above): return .moveCheckItem(id: id, cardId: c, checklistId: cl, above: above.filter { !gone.contains($0) })
        case .sortList(let id, let ids): return .sortList(id: id, cardIds: ids.filter { !gone.contains($0) })
        default: return self
        }
    }
}

// MARK: - Replaying

/// What happened when the next queued change was sent.
public enum SyncStep: Equatable, Sendable {
    /// It reached the server. `applied` is the change with server ids, to apply to the snapshots (nil when
    /// there's nothing reliable to apply, e.g. a create whose new id couldn't be found).
    case synced(PendingOp, applied: Change?)
    /// Part of it clashed with someone else's edit and is kept in `failed`; `applied` is what was sent.
    case conflict(PendingOp, applied: Change?)
    /// It can't be sent and is in `failed`.
    case failed(PendingOp, reason: String)
    /// The server couldn't be reached. The change is still first in line.
    case offline
    /// The server had trouble. Wait, then carry on (the change is still first in line).
    case retry(after: TimeInterval)
    case signedOut
    case cancelled
}

public extension OfflineQueue {
    /// Server errors in a row before a change is given up on.
    static let maxAttempts = 3

    /// The next change, with server ids, ready to send. Changes that need something that never synced
    /// fail on the way. A create is marked as sent (and its look-alikes noted) so that if we never hear
    /// back, the retry looks for it instead of creating a duplicate. `inDoubt`: it was already sent once.
    /// `snapshots` gives the latest server board and card for an op.
    mutating func prepareNext(replayer: Replayer, now: Date = Date(), snapshots: (PendingOp) -> (board: Board?, card: Card?)) -> (op: PendingOp, inDoubt: Bool)? {
        while let op = next {
            if !unresolved(op.change).isEmpty {
                fail(op.id, reason: "It needs something else that couldn't sync.")
                continue
            }
            var ready = op
            ready.change = resolved(op.change)
            let inDoubt = op.sentAt != nil
            if ready.change.created != nil, !inDoubt {
                let (board, card) = snapshots(ready)
                let existing = replayer.lookalikes(ready.change, board: board, card: card) ?? []
                markSent(op.id, at: now, existing: existing)
                ready.sentAt = now
                ready.existing = existing
            }
            sending = op.id
            return (ready, inDoubt)
        }
        return nil
    }

    /// Records how sending `op` (from `prepareNext`) went.
    mutating func finish(_ op: PendingOp, _ result: Result<Replayer.Outcome, Error>) -> SyncStep {
        if sending == op.id { sending = nil }
        let creates = op.change.created != nil
        switch result {
        case .success(.done(let createdId)):
            complete(op.id, createdId: createdId)
            if let temp = op.change.created {
                guard let createdId else { return .synced(op, applied: nil) }
                return .synced(op, applied: op.change.mapIds { $0 == temp ? createdId : $0 })
            }
            return .synced(op, applied: op.change)
        case .success(.conflict(let sent, let kept, let conflicts)):
            conflict(op.id, kept: kept, conflicts: conflicts)
            return .conflict(op, applied: sent)
        case .success(.rejected(let reason)):
            fail(op.id, reason: reason)
            return .failed(op, reason: reason)
        case .failure(let error):
            let kind = Reachability.classify(error)
            if creates, kind != .rejected, !Reachability.mayHaveReachedServer(error) { clearSent(op.id) }
            switch kind {
            case .offline: return .offline
            case .signedOut: return .signedOut
            case .cancelled: return .cancelled
            case .retryLater:
                let n = noteAttempt(op.id)
                guard n >= Self.maxAttempts else { return .retry(after: pow(2, Double(n))) }
                fail(op.id, reason: error.localizedDescription)
                return .failed(op, reason: error.localizedDescription)
            case .rejected:
                fail(op.id, reason: error.localizedDescription)
                return .failed(op, reason: error.localizedDescription)
            }
        }
    }
}
