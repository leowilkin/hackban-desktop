import Foundation

// Offline edits. Every edit that can work without the server is a `Change`, queued as a `PendingOp` and
// sent in order. The same `Change` also says what it does locally (`apply(to:)`), so the app can show
// "last server snapshot + changes still waiting" and recompute that whenever a fresh snapshot arrives.

/// Ids for things made on this device, until the server gives them real ones.
public enum TempID {
    public static let prefix = "local:"
    public static func make() -> String { prefix + UUID().uuidString.lowercased() }
    public static func isTemp(_ id: String) -> Bool { id.hasPrefix(prefix) }
}

/// Where a moved item lands, kept as the items above it (nearest first) rather than one `afterId`, so the
/// drop spot survives other people moving or deleting the card it was dropped under.
public enum Anchors {
    /// How many neighbours a move remembers.
    public static let depth = 20

    /// The items above position `index` in `ids`, nearest first.
    public static func above(_ index: Int, in ids: [String]) -> [String] {
        Array(ids.prefix(max(0, min(index, ids.count))).reversed().prefix(depth))
    }

    /// The id to put the item after: the nearest of `above` that's still in `ids`, or nil for the top.
    public static func after(_ above: [String], in ids: [String]) -> String? {
        let present = Set(ids)
        return above.first { present.contains($0) }
    }

    /// Insertion index in `ids` for an item that goes after `after(above, in: ids)`.
    public static func index(_ above: [String], in ids: [String]) -> Int {
        guard let a = after(above, in: ids), let i = ids.firstIndex(of: a) else { return 0 }
        return i + 1
    }
}

/// Fields a check-item edit sets. `due` and `member` are double optionals: `.some(nil)` clears.
public struct CheckItemPatch: Equatable, Sendable {
    public var name: String?
    public var complete: Bool?
    public var due: Date??
    /// The whole user, so the assignee shows before the server answers.
    public var member: User??

    public init(name: String? = nil, complete: Bool? = nil, due: Date?? = nil, member: User?? = nil) {
        self.name = name; self.complete = complete; self.due = due; self.member = member
    }

    public var isEmpty: Bool { name == nil && complete == nil && due == nil && member == nil }

    /// The same fields, holding `item`'s current values.
    public func base(from item: CheckItem) -> CheckItemPatch {
        CheckItemPatch(
            name: name.map { _ in item.name },
            complete: complete.map { _ in item.complete },
            due: due.map { _ in item.due },
            member: member.map { _ in item.member ?? item.memberId.map { User(id: $0) } }
        )
    }

    /// `other`'s fields on top of these.
    public func merged(with other: CheckItemPatch) -> CheckItemPatch {
        CheckItemPatch(name: other.name ?? name, complete: other.complete ?? complete, due: other.due ?? due, member: other.member ?? member)
    }

    /// Keeps the fields the two don't already agree on.
    public func removingFields(equalTo base: CheckItemPatch) -> CheckItemPatch {
        var p = self
        if p.name != nil, p.name == base.name { p.name = nil }
        if p.complete != nil, p.complete == base.complete { p.complete = nil }
        if p.due != nil, p.due == base.due { p.due = nil }
        if let m = p.member, let b = base.member, m?.id == b?.id { p.member = nil }
        return p
    }

    func apply(to i: inout CheckItem) {
        if let v = name { i.name = v }
        if let v = complete { i.complete = v }
        if let v = due { i.due = v }
        if let v = member { i.memberId = v?.id; i.member = v }
    }
}

/// Fields a list edit sets. `color` is a double optional: `.some(nil)` clears.
public struct ListPatch: Equatable, Sendable {
    public var name: String?
    public var color: String??
    public var closed: Bool?

    public init(name: String? = nil, color: String?? = nil, closed: Bool? = nil) {
        self.name = name; self.color = color; self.closed = closed
    }

    public var isEmpty: Bool { name == nil && color == nil && closed == nil }

    public func merged(with other: ListPatch) -> ListPatch {
        ListPatch(name: other.name ?? name, color: other.color ?? color, closed: other.closed ?? closed)
    }
}

public extension HackbanAPI.CardPatch {
    var isEmpty: Bool { input.isEmpty }

    /// The same fields, holding `c`'s current values (what a conflict check compares the server against).
    func base(from c: Card) -> HackbanAPI.CardPatch {
        var b = HackbanAPI.CardPatch()
        if title != nil { b.title = c.title }
        if description != nil { b.description = c.description }
        if start != nil { b.start = .some(c.start) }
        if due != nil { b.due = .some(c.due) }
        if dueComplete != nil {
            b.dueComplete = c.dueComplete
            // Completing a repeating card moves its due date: remember it to tell whether that happened.
            if c.recurrence != nil, due == nil { b.due = .some(c.due) }
        }
        if coverColor != nil { b.coverColor = .some(c.coverColor) }
        if coverAttachmentId != nil { b.coverAttachmentId = .some(c.coverAttachmentId) }
        if coverSize != nil { b.coverSize = c.coverSize }
        if closed != nil { b.closed = c.closed }
        if recurrence != nil { b.recurrence = .some(c.recurrence) }
        return b
    }

    /// `other`'s fields on top of these.
    func merged(with other: HackbanAPI.CardPatch) -> HackbanAPI.CardPatch {
        var p = self
        if let v = other.title { p.title = v }
        if let v = other.description { p.description = v }
        if let v = other.start { p.start = v }
        if let v = other.due { p.due = v }
        if let v = other.dueComplete { p.dueComplete = v }
        // A colour cover and an image cover replace each other (the server clears the other one).
        if let v = other.coverColor {
            p.coverColor = v
            if v != nil { p.coverAttachmentId = nil }
        }
        if let v = other.coverAttachmentId {
            p.coverAttachmentId = v
            if v != nil { p.coverColor = nil }
        }
        if let v = other.coverSize { p.coverSize = v }
        if let v = other.closed { p.closed = v }
        if let v = other.recurrence { p.recurrence = v }
        return p
    }

    /// `other`'s fields only where these don't have one (merging bases keeps the earliest).
    func filling(from other: HackbanAPI.CardPatch) -> HackbanAPI.CardPatch { other.merged(with: self) }

    /// Keeps the fields that differ from `base`.
    func removingFields(equalTo base: HackbanAPI.CardPatch) -> HackbanAPI.CardPatch {
        var p = self
        if p.title != nil, p.title == base.title { p.title = nil }
        if p.description != nil, p.description == base.description { p.description = nil }
        if p.start != nil, p.start == base.start { p.start = nil }
        if p.due != nil, p.due == base.due { p.due = nil }
        if p.dueComplete != nil, p.dueComplete == base.dueComplete { p.dueComplete = nil }
        if p.coverColor != nil, p.coverColor == base.coverColor { p.coverColor = nil }
        if p.coverAttachmentId != nil, p.coverAttachmentId == base.coverAttachmentId { p.coverAttachmentId = nil }
        if p.coverSize != nil, p.coverSize == base.coverSize { p.coverSize = nil }
        if p.closed != nil, p.closed == base.closed { p.closed = nil }
        if p.recurrence != nil, p.recurrence == base.recurrence { p.recurrence = nil }
        return p
    }

    /// Only the fields in `keep` ("title", "description").
    func only(_ keep: Set<String>) -> HackbanAPI.CardPatch {
        var p = HackbanAPI.CardPatch()
        if keep.contains("title") { p.title = title }
        if keep.contains("description") { p.description = description }
        return p
    }
}

/// One edit, in terms the server understands once its ids are real.
public enum Change: Codable, Equatable, Sendable {
    case createCard(id: String, listId: String, title: String, atTop: Bool)
    case updateCard(id: String, patch: HackbanAPI.CardPatch, base: HackbanAPI.CardPatch)
    case moveCard(id: String, listId: String, above: [String])
    case setLabel(cardId: String, label: Label, on: Bool, was: Bool)
    case setMember(cardId: String, user: User, on: Bool, was: Bool)
    case watch(cardId: String, on: Bool, was: Bool)
    case deleteCard(id: String)

    case addChecklist(id: String, cardId: String, name: String)
    case renameChecklist(id: String, cardId: String, name: String)
    case deleteChecklist(id: String, cardId: String)
    case addCheckItem(id: String, cardId: String, checklistId: String, name: String)
    case updateCheckItem(id: String, cardId: String, patch: CheckItemPatch, base: CheckItemPatch)
    case moveCheckItem(id: String, cardId: String, checklistId: String, above: [String])
    case deleteCheckItem(id: String, cardId: String)

    case addComment(id: String, cardId: String, text: String, author: User, at: Date)
    case editComment(id: String, cardId: String, text: String)
    case deleteComment(id: String, cardId: String)

    case addLink(id: String, cardId: String, url: String, name: String?)
    case renameAttachment(id: String, cardId: String, name: String)
    case deleteAttachment(id: String, cardId: String)

    case createList(id: String, name: String)
    case updateList(id: String, patch: ListPatch)
    case moveList(id: String, above: [String])
    case sortList(id: String, cardIds: [String])

    /// The id this change makes up for something new.
    public var created: String? {
        switch self {
        case .createCard(let id, _, _, _), .addChecklist(let id, _, _), .addCheckItem(let id, _, _, _),
             .addComment(let id, _, _, _, _), .addLink(let id, _, _, _), .createList(let id, _):
            return id
        default: return nil
        }
    }

    /// What it changes: the card, list, checklist, item, comment or attachment.
    public var subject: String {
        switch self {
        case .createCard(let id, _, _, _), .updateCard(let id, _, _), .moveCard(let id, _, _), .deleteCard(let id),
             .addChecklist(let id, _, _), .renameChecklist(let id, _, _), .deleteChecklist(let id, _),
             .addCheckItem(let id, _, _, _), .updateCheckItem(let id, _, _, _), .moveCheckItem(let id, _, _, _), .deleteCheckItem(let id, _),
             .addComment(let id, _, _, _, _), .editComment(let id, _, _), .deleteComment(let id, _),
             .addLink(let id, _, _, _), .renameAttachment(let id, _, _), .deleteAttachment(let id, _),
             .createList(let id, _), .updateList(let id, _), .moveList(let id, _), .sortList(let id, _):
            return id
        case .setLabel(let c, _, _, _), .setMember(let c, _, _, _), .watch(let c, _, _):
            return c
        }
    }

    /// The card it's on, for card-level changes.
    public var cardId: String? {
        switch self {
        case .createCard(let id, _, _, _), .updateCard(let id, _, _), .moveCard(let id, _, _), .deleteCard(let id): return id
        case .setLabel(let c, _, _, _), .setMember(let c, _, _, _), .watch(let c, _, _): return c
        case .addChecklist(_, let c, _), .renameChecklist(_, let c, _), .deleteChecklist(_, let c),
             .addCheckItem(_, let c, _, _), .updateCheckItem(_, let c, _, _), .moveCheckItem(_, let c, _, _), .deleteCheckItem(_, let c),
             .addComment(_, let c, _, _, _), .editComment(_, let c, _), .deleteComment(_, let c),
             .addLink(_, let c, _, _), .renameAttachment(_, let c, _), .deleteAttachment(_, let c):
            return c
        case .createList, .updateList, .moveList, .sortList: return nil
        }
    }

    /// Ids that have to exist on the server before this can be sent (not counting `created`, or the
    /// neighbours a move lands next to, which are only hints).
    public var references: [String] {
        switch self {
        case .createCard(_, let listId, _, _): return [listId]
        case .moveCard(let id, let listId, _): return [id, listId]
        case .addChecklist(_, let c, _): return [c]
        case .addCheckItem(_, let c, let cl, _): return [c, cl]
        case .moveCheckItem(let id, let c, let cl, _): return [id, c, cl]
        case .addComment(_, let c, _, _, _), .addLink(_, let c, _, _): return [c]
        case .createList: return []
        case .sortList(let id, _): return [id]
        case .renameChecklist(let id, let c, _), .deleteChecklist(let id, let c), .updateCheckItem(let id, let c, _, _),
             .deleteCheckItem(let id, let c), .editComment(let id, let c, _), .deleteComment(let id, let c),
             .renameAttachment(let id, let c, _), .deleteAttachment(let id, let c):
            return [id, c]
        default: return [subject]
        }
    }

    public var isDelete: Bool {
        switch self {
        case .deleteCard, .deleteChecklist, .deleteCheckItem, .deleteComment, .deleteAttachment: return true
        default: return false
        }
    }

    /// The same change with every id passed through `f` (temp ids → server ids).
    public func mapIds(_ f: (String) -> String) -> Change {
        switch self {
        case .createCard(let id, let l, let t, let top): return .createCard(id: f(id), listId: f(l), title: t, atTop: top)
        case .updateCard(let id, let p, let b): return .updateCard(id: f(id), patch: p, base: b)
        case .moveCard(let id, let l, let above): return .moveCard(id: f(id), listId: f(l), above: above.map(f))
        case .setLabel(let c, let l, let on, let was): return .setLabel(cardId: f(c), label: l, on: on, was: was)
        case .setMember(let c, let u, let on, let was): return .setMember(cardId: f(c), user: u, on: on, was: was)
        case .watch(let c, let on, let was): return .watch(cardId: f(c), on: on, was: was)
        case .deleteCard(let id): return .deleteCard(id: f(id))
        case .addChecklist(let id, let c, let n): return .addChecklist(id: f(id), cardId: f(c), name: n)
        case .renameChecklist(let id, let c, let n): return .renameChecklist(id: f(id), cardId: f(c), name: n)
        case .deleteChecklist(let id, let c): return .deleteChecklist(id: f(id), cardId: f(c))
        case .addCheckItem(let id, let c, let cl, let n): return .addCheckItem(id: f(id), cardId: f(c), checklistId: f(cl), name: n)
        case .updateCheckItem(let id, let c, let p, let b): return .updateCheckItem(id: f(id), cardId: f(c), patch: p, base: b)
        case .moveCheckItem(let id, let c, let cl, let above): return .moveCheckItem(id: f(id), cardId: f(c), checklistId: f(cl), above: above.map(f))
        case .deleteCheckItem(let id, let c): return .deleteCheckItem(id: f(id), cardId: f(c))
        case .addComment(let id, let c, let t, let a, let at): return .addComment(id: f(id), cardId: f(c), text: t, author: a, at: at)
        case .editComment(let id, let c, let t): return .editComment(id: f(id), cardId: f(c), text: t)
        case .deleteComment(let id, let c): return .deleteComment(id: f(id), cardId: f(c))
        case .addLink(let id, let c, let u, let n): return .addLink(id: f(id), cardId: f(c), url: u, name: n)
        case .renameAttachment(let id, let c, let n): return .renameAttachment(id: f(id), cardId: f(c), name: n)
        case .deleteAttachment(let id, let c): return .deleteAttachment(id: f(id), cardId: f(c))
        case .createList(let id, let n): return .createList(id: f(id), name: n)
        case .updateList(let id, let p): return .updateList(id: f(id), patch: p)
        case .moveList(let id, let above): return .moveList(id: f(id), above: above.map(f))
        case .sortList(let id, let ids): return .sortList(id: f(id), cardIds: ids.map(f))
        }
    }

    /// Changes whose result has server-made parts (positions, counts, a repeating card's next date), so
    /// the board is worth refetching once they've synced.
    public var refreshesBoard: Bool {
        switch self {
        case .createCard, .createList, .addCheckItem, .updateCheckItem, .deleteCheckItem, .deleteChecklist,
             .addComment, .deleteComment, .addLink, .deleteAttachment:
            return true
        case .updateCard(_, let p, _): return p.dueComplete == true || p.closed == false
        default: return false
        }
    }

    /// A few words for the list of changes waiting to sync. `title` is the card's (or list's) name.
    public func describe(_ title: String?) -> String {
        let t = title.map { "“\($0)”" }
        func on(_ s: String) -> String { t.map { "\(s) on \($0)" } ?? s }
        switch self {
        case .createCard: return "Added \(t ?? "a card")"
        case .updateCard(_, let p, _):
            let what: String
            if p.closed == true { what = "Archived" }
            else if p.closed == false { what = "Restored" }
            else if p.title != nil { what = "Renamed" }
            else if p.description != nil { return "Edited the description of \(t ?? "a card")" }
            else if p.dueComplete != nil { what = p.dueComplete! ? "Completed" : "Marked incomplete" }
            else if p.due != nil || p.start != nil { return "Changed the dates on \(t ?? "a card")" }
            else { what = "Edited" }
            return "\(what) \(t ?? "a card")"
        case .moveCard: return "Moved \(t ?? "a card")"
        case .setLabel(_, let l, let on_, _):
            let name = l.name.isEmpty ? (l.color ?? "a") : l.name
            return on_ ? on("Added label \(name)") : on("Removed label \(name)")
        case .setMember(_, let u, let on_, _): return on_ ? on("Added \(u.displayName)") : on("Removed \(u.displayName)")
        case .watch(_, let on_, _): return on_ ? "Watching \(t ?? "a card")" : "Stopped watching \(t ?? "a card")"
        case .deleteCard: return "Deleted \(t ?? "a card")"
        case .addChecklist(_, _, let n): return on("Added checklist “\(n)”")
        case .renameChecklist(_, _, let n): return on("Renamed a checklist to “\(n)”")
        case .deleteChecklist: return on("Deleted a checklist")
        case .addCheckItem(_, _, _, let n): return on("Added “\(n)”")
        case .updateCheckItem(_, _, let p, _):
            if let c = p.complete { return on(c ? "Checked an item" : "Unchecked an item") }
            return on("Edited a checklist item")
        case .moveCheckItem: return on("Moved a checklist item")
        case .deleteCheckItem: return on("Deleted a checklist item")
        case .addComment: return on("Commented")
        case .editComment: return on("Edited a comment")
        case .deleteComment: return on("Deleted a comment")
        case .addLink: return on("Attached a link")
        case .renameAttachment: return on("Renamed an attachment")
        case .deleteAttachment: return on("Deleted an attachment")
        case .createList(_, let n): return "Added list “\(n)”"
        case .updateList(_, let p):
            if p.closed == true { return "Archived list \(t ?? "")" }
            if let n = p.name { return "Renamed a list to “\(n)”" }
            return "Changed the colour of list \(t ?? "")"
        case .moveList: return "Moved list \(t ?? "")"
        case .sortList: return "Sorted list \(t ?? "")"
        }
    }
}

// MARK: - Local effects

// Applying a change twice is the same as applying it once, so a change can be re-applied to a snapshot
// that may or may not include it already.

public extension Change {
    func apply(to b: inout Board) {
        switch self {
        case .createCard(let id, let listId, let title, let atTop):
            guard b.list(containing: id) == nil, let li = b.lists.firstIndex(where: { $0.id == listId }) else { return }
            let card = Card(localId: id, listId: listId, title: title)
            if atTop { b.lists[li].cards = [card] + b.lists[li].openCards } else { b.lists[li].cards = b.lists[li].openCards + [card] }

        case .updateCard(let id, let patch, _):
            guard let (li, ci) = b.list(containing: id) else { return }
            if patch.closed == true { b.lists[li].cards!.remove(at: ci) } else { patch.apply(to: &b.lists[li].cards![ci]) }

        case .moveCard(let id, let listId, let above):
            guard let (li, ci) = b.list(containing: id), let ti = b.lists.firstIndex(where: { $0.id == listId }) else { return }
            var card = b.lists[li].cards!.remove(at: ci)
            card.listId = listId
            var target = b.lists[ti].openCards
            target.insert(card, at: Anchors.index(above, in: target.map(\.id)))
            b.lists[ti].cards = target

        case .setLabel(let cardId, let label, let on, _):
            let current = b.label(label.id) ?? label
            editCard(cardId, in: &b) { c in
                c.labels = (c.labels ?? []).filter { $0.labelId != label.id }
                if on { c.labels!.append(CardLabel(cardId: cardId, labelId: label.id, label: current)) }
            }

        case .setMember(let cardId, let user, let on, _):
            editCard(cardId, in: &b) { c in
                c.members = (c.members ?? []).filter { $0.userId != user.id }
                if on { c.members!.append(CardMember(cardId: cardId, userId: user.id, user: user)) }
            }

        case .watch(let cardId, let on, _):
            editCard(cardId, in: &b) { $0.watching = on }

        case .deleteCard(let id):
            guard let (li, ci) = b.list(containing: id) else { return }
            b.lists[li].cards!.remove(at: ci)

        case .createList(let id, let name):
            guard !b.lists.contains(where: { $0.id == id }) else { return }
            b.lists.append(BoardList(id: id, boardId: b.id, name: name, pos: "", color: nil, closed: false, cards: []))

        case .updateList(let id, let patch):
            guard let i = b.lists.firstIndex(where: { $0.id == id }) else { return }
            if patch.closed == true { b.lists.remove(at: i); return }
            if let v = patch.name { b.lists[i].name = v }
            if let v = patch.color { b.lists[i].color = v }

        case .moveList(let id, let above):
            guard let i = b.lists.firstIndex(where: { $0.id == id }) else { return }
            let list = b.lists.remove(at: i)
            b.lists.insert(list, at: Anchors.index(above, in: b.lists.map(\.id)))

        case .sortList(let id, let ids):
            guard let i = b.lists.firstIndex(where: { $0.id == id }) else { return }
            let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let cards = b.lists[i].openCards.enumerated().sorted { x, y in
                (order[x.element.id] ?? ids.count + x.offset, x.offset) < (order[y.element.id] ?? ids.count + y.offset, y.offset)
            }
            b.lists[i].cards = cards.map(\.element)

        default:
            // Checklists, comments and attachments only show on the full card. Card-front counts catch up
            // when the board is next fetched.
            break
        }
    }

    /// The full card (`card.get`). Changes to other cards leave it alone.
    func apply(to c: inout Card) {
        guard cardId == c.id else { return }
        switch self {
        case .updateCard(_, let patch, _): patch.apply(to: &c)
        case .moveCard(_, let listId, _):
            if c.listId != listId { c.listId = listId; c.list?.id = listId }
        case .setLabel(_, let label, let on, _):
            c.labels = (c.labels ?? []).filter { $0.labelId != label.id }
            if on { c.labels!.append(CardLabel(cardId: c.id, labelId: label.id, label: label)) }
        case .setMember(_, let user, let on, _):
            c.members = (c.members ?? []).filter { $0.userId != user.id }
            if on { c.members!.append(CardMember(cardId: c.id, userId: user.id, user: user)) }
        case .watch(_, let on, _): c.watching = on

        case .addChecklist(let id, _, let name):
            guard !(c.checklists ?? []).contains(where: { $0.id == id }) else { return }
            c.checklists = (c.checklists ?? []) + [Checklist(id: id, cardId: c.id, name: name, pos: "", items: [])]
        case .renameChecklist(let id, _, let name):
            if let i = c.checklists?.firstIndex(where: { $0.id == id }) { c.checklists![i].name = name }
        case .deleteChecklist(let id, _):
            c.checklists?.removeAll { $0.id == id }

        case .addCheckItem(let id, _, let checklistId, let name):
            guard let i = c.checklists?.firstIndex(where: { $0.id == checklistId }), !c.checklists![i].items.contains(where: { $0.id == id }) else { return }
            c.checklists![i].items.append(CheckItem(id: id, checklistId: checklistId, name: name, pos: "", complete: false, due: nil, memberId: nil, member: nil))
        case .updateCheckItem(let id, _, let patch, _):
            for ci in (c.checklists ?? []).indices {
                if let ii = c.checklists![ci].items.firstIndex(where: { $0.id == id }) { patch.apply(to: &c.checklists![ci].items[ii]) }
            }
        case .moveCheckItem(let id, _, let checklistId, let above):
            guard var lists = c.checklists, lists.contains(where: { $0.id == checklistId }) else { return }
            var moving: CheckItem?
            for ci in lists.indices { if let ii = lists[ci].items.firstIndex(where: { $0.id == id }) { moving = lists[ci].items.remove(at: ii) } }
            guard var item = moving, let ti = lists.firstIndex(where: { $0.id == checklistId }) else { return }
            item.checklistId = checklistId
            lists[ti].items.insert(item, at: Anchors.index(above, in: lists[ti].items.map(\.id)))
            c.checklists = lists
        case .deleteCheckItem(let id, _):
            for ci in (c.checklists ?? []).indices { c.checklists![ci].items.removeAll { $0.id == id } }

        case .addComment(let id, _, let text, let author, let at):
            guard !(c.comments ?? []).contains(where: { $0.id == id }) else { return }
            c.comments = [Comment(id: id, cardId: c.id, authorId: author.id, text: text, createdAt: at, editedAt: nil, author: author)] + (c.comments ?? [])
        case .editComment(let id, _, let text):
            if let i = c.comments?.firstIndex(where: { $0.id == id }), c.comments![i].text != text {
                c.comments![i].text = text
                c.comments![i].editedAt = c.comments![i].editedAt ?? Date()
            }
        case .deleteComment(let id, _):
            c.comments?.removeAll { $0.id == id }

        case .addLink(let id, _, let url, let name):
            guard !(c.attachments ?? []).contains(where: { $0.id == id }) else { return }
            let a = Attachment(id: id, cardId: c.id, uploaderId: nil, name: name ?? url, url: url, mimeType: nil, size: nil, isUpload: false, createdAt: nil, uploader: nil)
            c.attachments = [a] + (c.attachments ?? [])
        case .renameAttachment(let id, _, let name):
            if let i = c.attachments?.firstIndex(where: { $0.id == id }) { c.attachments![i].name = name }
        case .deleteAttachment(let id, _):
            c.attachments?.removeAll { $0.id == id }
            if c.coverAttachmentId == id { c.coverAttachmentId = nil; c.coverUrl = nil }

        case .createCard, .deleteCard, .createList, .updateList, .moveList, .sortList:
            break
        }
    }
}

private func editCard(_ id: String, in b: inout Board, _ f: (inout Card) -> Void) {
    guard let (li, ci) = b.list(containing: id) else { return }
    f(&b.lists[li].cards![ci])
}

/// A queued change and what's known about sending it.
public struct PendingOp: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// The board it's on, so the board can be refetched (for conflict checks) before its changes replay.
    public var boardId: String
    public var madeAt: Date
    public var change: Change
    /// Set just before a create is sent, cleared if it certainly never arrived. Still set on a retry means
    /// it may already exist on the server: look for it before creating it again.
    public var sentAt: Date?
    /// For creates: ids of look-alikes that already existed when it was sent, so a lookup can't adopt one.
    public var existing: [String]?
    /// Failed tries that might work later (server errors, rate limits).
    public var attempts: Int

    public init(id: String = UUID().uuidString, boardId: String, madeAt: Date = Date(), change: Change) {
        self.id = id
        self.boardId = boardId
        self.madeAt = madeAt
        self.change = change
        self.attempts = 0
    }
}

/// Someone else changed the same text while this edit waited.
public struct FieldConflict: Codable, Equatable, Sendable {
    /// "title" or "description"
    public var field: String
    public var theirs: String
    public var mine: String

    public init(field: String, theirs: String, mine: String) {
        self.field = field; self.theirs = theirs; self.mine = mine
    }
}

/// A change that couldn't be sent, kept until you retry or discard it.
public struct FailedOp: Codable, Equatable, Identifiable, Sendable {
    public var op: PendingOp
    public var reason: String
    /// Set when it's a conflict rather than an error.
    public var conflicts: [FieldConflict]?
    public var failedAt: Date

    public var id: String { op.id }
    public var isConflict: Bool { conflicts != nil }

    public init(op: PendingOp, reason: String, conflicts: [FieldConflict]? = nil, failedAt: Date = Date()) {
        self.op = op; self.reason = reason; self.conflicts = conflicts; self.failedAt = failedAt
    }
}

// MARK: - Coding

// Patches use double optionals (absent = leave alone, `.some(nil)` = clear), which synthesized Codable
// collapses. A nullable field is written as `[]` to clear it and `[value]` to set it.

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ v: T??, forKey key: Key) throws {
        guard let v else { return }
        try encode(v.map { [$0] } ?? [], forKey: key)
    }
}

private extension KeyedDecodingContainer {
    func decodeNullable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T?? {
        guard let a = try decodeIfPresent([T].self, forKey: key) else { return nil }
        return .some(a.first)
    }
}

extension HackbanAPI.CardPatch: Codable {
    enum CodingKeys: String, CodingKey { case title, description, start, due, dueComplete, coverColor, coverAttachmentId, coverSize, closed, recurrence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title),
            description: try c.decodeIfPresent(String.self, forKey: .description),
            start: try c.decodeNullable(Date.self, forKey: .start),
            due: try c.decodeNullable(Date.self, forKey: .due),
            dueComplete: try c.decodeIfPresent(Bool.self, forKey: .dueComplete),
            coverColor: try c.decodeNullable(String.self, forKey: .coverColor),
            coverAttachmentId: try c.decodeNullable(String.self, forKey: .coverAttachmentId),
            coverSize: try c.decodeIfPresent(String.self, forKey: .coverSize),
            closed: try c.decodeIfPresent(Bool.self, forKey: .closed),
            recurrence: try c.decodeNullable(String.self, forKey: .recurrence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeNullable(start, forKey: .start)
        try c.encodeNullable(due, forKey: .due)
        try c.encodeIfPresent(dueComplete, forKey: .dueComplete)
        try c.encodeNullable(coverColor, forKey: .coverColor)
        try c.encodeNullable(coverAttachmentId, forKey: .coverAttachmentId)
        try c.encodeIfPresent(coverSize, forKey: .coverSize)
        try c.encodeIfPresent(closed, forKey: .closed)
        try c.encodeNullable(recurrence, forKey: .recurrence)
    }
}

extension CheckItemPatch: Codable {
    enum CodingKeys: String, CodingKey { case name, complete, due, member }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decodeIfPresent(String.self, forKey: .name),
            complete: try c.decodeIfPresent(Bool.self, forKey: .complete),
            due: try c.decodeNullable(Date.self, forKey: .due),
            member: try c.decodeNullable(User.self, forKey: .member)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(complete, forKey: .complete)
        try c.encodeNullable(due, forKey: .due)
        try c.encodeNullable(member, forKey: .member)
    }
}

extension ListPatch: Codable {
    enum CodingKeys: String, CodingKey { case name, color, closed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decodeIfPresent(String.self, forKey: .name),
            color: try c.decodeNullable(String.self, forKey: .color),
            closed: try c.decodeIfPresent(Bool.self, forKey: .closed)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeNullable(color, forKey: .color)
        try c.encodeIfPresent(closed, forKey: .closed)
    }
}
