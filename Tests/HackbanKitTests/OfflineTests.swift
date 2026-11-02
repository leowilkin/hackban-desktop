import Foundation
import XCTest
@testable import HackbanKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func card(_ id: String, _ list: String, _ title: String) -> Card { Card(localId: id, listId: list, title: title) }

private let urgent = Label(id: "l1", boardId: "b1", name: "Urgent", color: "red")
private let sam = User(id: "u2", name: "Sam Example")
private let me = User(id: "u1", name: "Pat Example")

private func makeBoard() -> Board {
    Board(id: "b1", name: "Launch", description: nil, workspaceId: "w1", background: "#0079bf", bgImage: nil, visibility: "workspace",
          closed: false, inviteRole: nil, inviteToken: nil, createdAt: nil, updatedAt: nil, workspace: nil, members: [], labels: [urgent],
          lists: [
              BoardList(id: "li1", boardId: "b1", name: "To Do", pos: "a0", color: nil, closed: false,
                        cards: [card("c1", "li1", "Write post"), card("c2", "li1", "Design"), card("c3", "li1", "Ship")]),
              BoardList(id: "li2", boardId: "b1", name: "Done", pos: "a1", color: nil, closed: false, cards: []),
          ],
          starred: false, myRole: "admin")
}

/// Whole milliseconds, which is what the files keep.
private let madeAt = Date(timeIntervalSince1970: 1_800_000_000)

private func op(_ change: Change) -> PendingOp { PendingOp(boardId: "b1", madeAt: madeAt, change: change) }

private func ids(_ b: Board, _ list: String) -> [String] { b.lists.first { $0.id == list }?.openCards.map(\.id) ?? [] }

final class OfflineModelTests: XCTestCase {
    func testAnchors() {
        XCTAssertEqual(Anchors.above(2, in: ["a", "b", "c"]), ["b", "a"])
        XCTAssertEqual(Anchors.above(0, in: ["a", "b"]), [])
        XCTAssertEqual(Anchors.after(["x", "b", "a"], in: ["a", "b", "c"]), "b")
        XCTAssertNil(Anchors.after(["x"], in: ["a"]))
        XCTAssertEqual(Anchors.index(["x", "a"], in: ["a", "b"]), 1)
        XCTAssertEqual(Anchors.index([], in: ["a", "b"]), 0)
    }

    func testOpsRoundTripThroughDisk() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000.5)
        let ops = [
            op(.updateCard(id: "c1", patch: .init(start: .some(nil), due: .some(due), coverColor: .some(nil)), base: .init(start: .some(due), due: .some(nil), coverColor: .some("red")))),
            op(.updateCheckItem(id: "i1", cardId: "c1", patch: .init(due: .some(nil), member: .some(sam)), base: .init(due: .some(due), member: .some(nil)))),
            op(.updateList(id: "li1", patch: .init(color: .some(nil)))),
            op(.addComment(id: TempID.make(), cardId: "c1", text: "hi", author: me, at: due)),
            op(.addLink(id: TempID.make(), cardId: "c1", url: "https://example.com", name: nil)),
            op(.setLabel(cardId: "c1", label: urgent, on: true, was: false)),
        ]
        var q = OfflineQueue(userId: "u1")
        for o in ops { q.enqueue(o) }
        let data = try OfflineStore.encode(q, savedAt: due)
        struct File: Decodable { let data: OfflineQueue }
        let back = try JSONDecoder.hackban.decode(File.self, from: data).data
        XCTAssertEqual(back, q)
        // "Clear the due date" survives, and isn't confused with "leave it alone".
        guard case .updateCard(_, let p, _) = back.pending[0].change else { return XCTFail() }
        XCTAssertEqual(p.start, .some(nil))
        XCTAssertNil(p.title)
        XCTAssertEqual(p.due, .some(due))
    }

    func testApplyToBoardIsIdempotent() {
        var b = makeBoard()
        let changes: [Change] = [
            .createCard(id: "local:n", listId: "li2", title: "New", atTop: false),
            .moveCard(id: "c1", listId: "li2", above: ["local:n"]),
            .setLabel(cardId: "c2", label: urgent, on: true, was: false),
            .setMember(cardId: "c2", user: sam, on: true, was: false),
            .updateCard(id: "c2", patch: .init(title: "Design v2", dueComplete: true), base: .init(title: "Design", dueComplete: false)),
            .updateCard(id: "c3", patch: .init(closed: true), base: .init(closed: false)),
            .createList(id: "local:l", name: "Later"),
            .moveList(id: "local:l", above: []),
            .updateList(id: "li1", patch: .init(name: "Backlog", color: .some("green"))),
        ]
        for c in changes { c.apply(to: &b) }
        let once = b
        for c in changes { c.apply(to: &b) }
        XCTAssertEqual(b, once)
        XCTAssertEqual(b.lists.map(\.id), ["local:l", "li1", "li2"])
        XCTAssertEqual(ids(b, "li2"), ["local:n", "c1"])
        XCTAssertEqual(ids(b, "li1"), ["c2"])
        let c2 = b.lists[1].openCards[0]
        XCTAssertEqual(c2.title, "Design v2")
        XCTAssertEqual(c2.labelIds, ["l1"])
        XCTAssertEqual(c2.memberIds, ["u2"])
        XCTAssertTrue(c2.dueComplete)
        XCTAssertEqual(b.lists[1].name, "Backlog")
        XCTAssertEqual(b.lists[1].color, "green")
    }

    func testMoveLandsUnderTheNearestCardStillThere() {
        var b = makeBoard()
        // Dropped under c2, which someone else has since deleted: it goes under c1 instead.
        Change.deleteCard(id: "c2").apply(to: &b)
        Change.moveCard(id: "c3", listId: "li1", above: ["c2", "c1"]).apply(to: &b)
        XCTAssertEqual(ids(b, "li1"), ["c1", "c3"])
        // Everything above it is gone: top.
        Change.moveCard(id: "c3", listId: "li1", above: ["zz"]).apply(to: &b)
        XCTAssertEqual(ids(b, "li1"), ["c3", "c1"])
    }

    func testSortList() {
        var b = makeBoard()
        Change.sortList(id: "li1", cardIds: ["c3", "c1"]).apply(to: &b)
        XCTAssertEqual(ids(b, "li1"), ["c3", "c1", "c2"])
    }

    func testApplyToCardDetail() {
        var c = card("c1", "li1", "Write post")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let changes: [Change] = [
            .addChecklist(id: "local:k", cardId: "c1", name: "Steps"),
            .addCheckItem(id: "local:i1", cardId: "c1", checklistId: "local:k", name: "One"),
            .addCheckItem(id: "local:i2", cardId: "c1", checklistId: "local:k", name: "Two"),
            .moveCheckItem(id: "local:i2", cardId: "c1", checklistId: "local:k", above: []),
            .updateCheckItem(id: "local:i1", cardId: "c1", patch: .init(complete: true, member: .some(sam)), base: .init(complete: false, member: .some(nil))),
            .addComment(id: "local:m", cardId: "c1", text: "first", author: me, at: at),
            .addLink(id: "local:a", cardId: "c1", url: "https://example.com", name: "Spec"),
            .renameAttachment(id: "local:a", cardId: "c1", name: "The spec"),
            .addComment(id: "local:other", cardId: "c9", text: "not this card", author: me, at: at),
        ]
        for ch in changes { ch.apply(to: &c) }
        let once = c
        for ch in changes { ch.apply(to: &c) }
        XCTAssertEqual(c, once)
        XCTAssertEqual(c.checklists?.first?.items.map(\.name), ["Two", "One"])
        XCTAssertEqual(c.checklists?.first?.items.last?.complete, true)
        XCTAssertEqual(c.checklists?.first?.items.last?.memberId, "u2")
        XCTAssertEqual(c.comments?.map(\.text), ["first"])
        XCTAssertEqual(c.attachments?.first?.name, "The spec")
        Change.deleteChecklist(id: "local:k", cardId: "c1").apply(to: &c)
        XCTAssertEqual(c.checklists, [])
    }
}

final class OfflineQueueTests: XCTestCase {
    func testTypingOfflineIsOneUpdateWithTheFirstBase() {
        var q = OfflineQueue()
        q.enqueue(op(.updateCard(id: "c1", patch: .init(description: "a"), base: .init(description: ""))))
        q.enqueue(op(.moveCard(id: "c1", listId: "li2", above: [])))
        q.enqueue(op(.updateCard(id: "c1", patch: .init(description: "ab"), base: .init(description: "a"))))
        q.enqueue(op(.updateCard(id: "c1", patch: .init(description: "abc", dueComplete: true), base: .init(description: "ab", dueComplete: false))))
        XCTAssertEqual(q.pending.count, 2)
        XCTAssertEqual(q.pending[0].change, .updateCard(id: "c1", patch: .init(description: "abc", dueComplete: true), base: .init(description: "", dueComplete: false)))
        // Back to how it was: nothing to send.
        q.enqueue(op(.updateCard(id: "c1", patch: .init(description: "", dueComplete: false), base: .init(description: "abc", dueComplete: true))))
        XCTAssertEqual(q.pending.map(\.change), [.moveCard(id: "c1", listId: "li2", above: [])])
    }

    func testEditsToNewThingsFoldIntoTheirCreate() {
        var q = OfflineQueue()
        q.enqueue(op(.createList(id: "local:l", name: "Doing")))
        q.enqueue(op(.createCard(id: "local:c", listId: "local:l", title: "Draft", atTop: false)))
        q.enqueue(op(.updateCard(id: "local:c", patch: .init(title: "Draft v2"), base: .init(title: "Draft"))))
        q.enqueue(op(.updateList(id: "local:l", patch: .init(name: "In progress"))))
        q.enqueue(op(.addComment(id: "local:m", cardId: "local:c", text: "hi", author: me, at: Date(timeIntervalSince1970: 0))))
        q.enqueue(op(.editComment(id: "local:m", cardId: "local:c", text: "hello")))
        q.enqueue(op(.addChecklist(id: "local:k", cardId: "local:c", name: "Steps")))
        q.enqueue(op(.renameChecklist(id: "local:k", cardId: "local:c", name: "To do")))
        q.enqueue(op(.addCheckItem(id: "local:i", cardId: "local:c", checklistId: "local:k", name: "One")))
        q.enqueue(op(.updateCheckItem(id: "local:i", cardId: "local:c", patch: .init(name: "Uno", complete: true), base: .init(name: "One", complete: false))))
        XCTAssertEqual(q.pending.map(\.change), [
            .createList(id: "local:l", name: "In progress"),
            .createCard(id: "local:c", listId: "local:l", title: "Draft v2", atTop: false),
            .addComment(id: "local:m", cardId: "local:c", text: "hello", author: me, at: Date(timeIntervalSince1970: 0)),
            .addChecklist(id: "local:k", cardId: "local:c", name: "To do"),
            .addCheckItem(id: "local:i", cardId: "local:c", checklistId: "local:k", name: "Uno"),
            .updateCheckItem(id: "local:i", cardId: "local:c", patch: .init(complete: true), base: .init(complete: false)),
        ])
    }

    func testColourAndImageCoversReplaceEachOther() {
        var q = OfflineQueue()
        q.enqueue(op(.updateCard(id: "c1", patch: .init(coverColor: .some("red")), base: .init(coverColor: .some(nil)))))
        q.enqueue(op(.updateCard(id: "c1", patch: .init(coverAttachmentId: .some("a1")), base: .init(coverAttachmentId: .some(nil)))))
        guard case .updateCard(_, let p, _) = q.pending[0].change else { return XCTFail() }
        XCTAssertEqual(p.coverAttachmentId, .some("a1"))
        XCTAssertTrue(p.coverColor == nil, "the colour is dropped, not cleared")
    }

    func testTogglesThatCancelOutDisappear() {
        var q = OfflineQueue()
        q.enqueue(op(.setLabel(cardId: "c1", label: urgent, on: true, was: false)))
        q.enqueue(op(.setMember(cardId: "c1", user: sam, on: false, was: true)))
        q.enqueue(op(.setLabel(cardId: "c1", label: urgent, on: false, was: true)))
        q.enqueue(op(.watch(cardId: "c1", on: true, was: false)))
        q.enqueue(op(.watch(cardId: "c1", on: false, was: true)))
        XCTAssertEqual(q.pending.map(\.change), [.setMember(cardId: "c1", user: sam, on: false, was: true)])
    }

    func testDeletingSomethingMadeOfflineDropsItsHistory() {
        var q = OfflineQueue()
        q.enqueue(op(.createCard(id: "local:c", listId: "li1", title: "Oops", atTop: false)))
        q.enqueue(op(.setLabel(cardId: "local:c", label: urgent, on: true, was: false)))
        q.enqueue(op(.addChecklist(id: "local:k", cardId: "local:c", name: "Steps")))
        q.enqueue(op(.addCheckItem(id: "local:i", cardId: "local:c", checklistId: "local:k", name: "One")))
        q.enqueue(op(.moveCard(id: "c1", listId: "li1", above: ["local:c", "c2"])))
        q.enqueue(op(.deleteCard(id: "local:c")))
        XCTAssertEqual(q.pending.map(\.change), [.moveCard(id: "c1", listId: "li1", above: ["c2"])])
    }

    func testNothingFoldsIntoAChangeThatMayHaveBeenSent() {
        var q = OfflineQueue()
        q.enqueue(op(.createCard(id: "local:c", listId: "li1", title: "Draft", atTop: false)))
        q.markSent(q.pending[0].id, existing: [])
        q.enqueue(op(.updateCard(id: "local:c", patch: .init(title: "Draft v2"), base: .init(title: "Draft"))))
        q.enqueue(op(.deleteCard(id: "local:c")))
        XCTAssertEqual(q.pending.count, 3)
        XCTAssertEqual(q.pending[0].change, .createCard(id: "local:c", listId: "li1", title: "Draft", atTop: false))
    }

    func testIdsAreMappedAndFailuresCascade() {
        var q = OfflineQueue()
        q.enqueue(op(.createList(id: "local:l", name: "Doing")))
        q.enqueue(op(.createCard(id: "local:c", listId: "local:l", title: "Draft", atTop: false)))
        q.enqueue(op(.setLabel(cardId: "local:c", label: urgent, on: true, was: false)))
        q.enqueue(op(.moveCard(id: "c1", listId: "local:l", above: ["local:c"])))
        q.enqueue(op(.updateCard(id: "c2", patch: .init(title: "Design v2"), base: .init(title: "Design"))))

        XCTAssertEqual(q.unresolved(q.pending[1].change), ["local:l"])
        q.complete(q.pending[0].id, createdId: "L1")
        XCTAssertEqual(q.resolved(q.pending[0].change), .createCard(id: "local:c", listId: "L1", title: "Draft", atTop: false))
        XCTAssertEqual(q.unresolved(q.pending[0].change), [])

        // The card can't be created, so labelling it fails too. The move only used it as a drop spot.
        q.fail(q.pending[0].id, reason: "nope")
        XCTAssertEqual(q.failed.map(\.op.change.subject), ["local:c", "local:c"])
        XCTAssertEqual(q.pending.count, 2)
        XCTAssertEqual(q.resolved(q.pending[0].change), .moveCard(id: "c1", listId: "L1", above: ["local:c"]))

        // Retrying brings the dependent back too, in order.
        q.retry(q.failed[0].id)
        XCTAssertEqual(q.failed, [])
        XCTAssertEqual(q.pending.map(\.change.subject), ["c1", "c2", "local:c", "local:c"])

        q.fail(q.pending[2].id, reason: "nope")
        q.discard(q.failed[0].id)
        XCTAssertEqual(q.failed, [])
        q.pruneIds()
        XCTAssertEqual(q.ids, ["local:l": "L1"])
    }

    func testUseMineRebasesOnTheirText() {
        var q = OfflineQueue()
        q.enqueue(op(.updateCard(id: "c1", patch: .init(title: "Mine"), base: .init(title: "Write post"))))
        let id = q.pending[0].id
        q.conflict(id, kept: q.pending[0].change, conflicts: [FieldConflict(field: "title", theirs: "Theirs", mine: "Mine")])
        XCTAssertTrue(q.failed[0].isConflict)
        q.retry(id, useMine: true)
        XCTAssertEqual(q.pending.map(\.change), [.updateCard(id: "c1", patch: .init(title: "Mine"), base: .init(title: "Theirs"))])
    }

    func testConflictRules() {
        var server = card("c1", "li1", "Theirs")
        server.description = "same"
        let base = HackbanAPI.CardPatch(title: "Write post", description: "same", dueComplete: false)
        let mine = HackbanAPI.CardPatch(title: "Mine", description: "new", dueComplete: true)
        let (send, conflicts) = ConflictCheck.cardUpdate(patch: mine, base: base, server: server)
        XCTAssertEqual(send, .init(description: "new", dueComplete: true))
        XCTAssertEqual(conflicts, [FieldConflict(field: "title", theirs: "Theirs", mine: "Mine")])

        // They made the same change: nothing to send, no conflict.
        server.title = "Mine"
        let same = ConflictCheck.cardUpdate(patch: .init(title: "Mine"), base: .init(title: "Write post"), server: server)
        XCTAssertTrue(same.send.isEmpty)
        XCTAssertEqual(same.conflicts, [])

        // Nothing to compare against: send it.
        XCTAssertEqual(ConflictCheck.cardUpdate(patch: mine, base: base, server: nil).send, mine)
    }

    func testFailureKinds() {
        XCTAssertEqual(Reachability.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(Reachability.classify(NSError(domain: NSURLErrorDomain, code: URLError.cannotConnectToHost.rawValue)), .offline)
        XCTAssertEqual(Reachability.classify(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(Reachability.classify(HackbanError.http(status: 502, message: "")), .offline)
        XCTAssertEqual(Reachability.classify(HackbanError.server(code: "INTERNAL_SERVER_ERROR", status: 500, message: "")), .retryLater)
        XCTAssertEqual(Reachability.classify(HackbanError.server(code: "TOO_MANY_REQUESTS", status: 429, message: "")), .retryLater)
        XCTAssertEqual(Reachability.classify(HackbanError.server(code: "BAD_REQUEST", status: 400, message: "")), .rejected)
        XCTAssertEqual(Reachability.classify(HackbanError.server(code: "UNAUTHORIZED", status: 401, message: "")), .signedOut)
        XCTAssertEqual(Reachability.classify(HackbanError.signedOut), .signedOut)
        XCTAssertEqual(Reachability.classify(HackbanError.oauth("HTTP 503")), .offline)

        XCTAssertFalse(Reachability.mayHaveReachedServer(URLError(.cannotConnectToHost)))
        XCTAssertFalse(Reachability.mayHaveReachedServer(URLError(.notConnectedToInternet)))
        XCTAssertTrue(Reachability.mayHaveReachedServer(URLError(.timedOut)))
        XCTAssertTrue(Reachability.mayHaveReachedServer(URLError(.networkConnectionLost)))
        XCTAssertTrue(Reachability.mayHaveReachedServer(HackbanError.http(status: 504, message: "")))
        XCTAssertFalse(Reachability.mayHaveReachedServer(HackbanError.http(status: 503, message: "")))
        XCTAssertFalse(Reachability.mayHaveReachedServer(HackbanError.server(code: "BAD_REQUEST", status: 400, message: "")))
    }
}

final class OfflineStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hackban-tests-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testSnapshotsRoundTrip() throws {
        let store = OfflineStore(root: dir)
        var b = makeBoard()
        b.lists[0].cards![0].due = Date(timeIntervalSince1970: 1_800_000_000.5)
        let at = Date(timeIntervalSince1970: 1_800_000_100)
        try store.write(b, OfflineStore.file("boards", b.id), savedAt: at)
        let back = try XCTUnwrap(store.load(Board.self, "boards/b1.json"))
        XCTAssertEqual(back.value, b)
        XCTAssertEqual(back.savedAt, at)

        store.save(b, "boards/later.json", delay: 60)
        XCTAssertFalse(store.exists("boards/later.json"))
        store.flush()
        XCTAssertNotNil(store.load(Board.self, "boards/later.json"))
    }

    func testOtherVersionsReadAsMissingAndCanBeSetAside() throws {
        let store = OfflineStore(root: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":99,"savedAt":"2026-11-01T00:00:00.000Z","data":{}}"#.utf8).write(to: store.url("queue.json"))
        XCTAssertNil(store.load(OfflineQueue.self, "queue.json"))
        let moved = try XCTUnwrap(store.setAside("queue.json"))
        XCTAssertFalse(store.exists("queue.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    func testPruneKeepsTheNewest() throws {
        let store = OfflineStore(root: dir)
        for (i, id) in ["a", "b", "c", "d"].enumerated() {
            try store.write(id, OfflineStore.file("cards", id))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i) * 100)], ofItemAtPath: store.url("cards/\(id).json").path)
        }
        store.prune("cards", keep: 2, except: ["a"])
        XCTAssertEqual(["a", "b", "c", "d"].filter { store.exists("cards/\($0).json") }, ["a", "c", "d"])
        XCTAssertEqual(OfflineStore.file("cards", "local:x/../y"), "cards/local_x____y.json")
    }
}

// MARK: - Replaying against a fake server

/// A tiny in-memory Hackban with one board and the procedures offline changes use.
final class FakeHackban: HTTP, @unchecked Sendable {
    var board = makeBoard()
    var checklists: [String: [Checklist]] = [:]
    var comments: [String: [Comment]] = [:]
    /// Procedures called, in order.
    var calls: [String] = []
    var offline = false
    /// The next call to this procedure is carried out, then the connection drops before the answer.
    var dropAfter: String?
    /// Answers for procedures, instead of carrying them out.
    var fail: [String: (Int, String)] = [:]
    /// The network goes away right after this procedure is carried out (and answered).
    var offlineAfter: String?
    private var n = 0
    private let lock = NSLock()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = try handleLocked(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func handleLocked(_ request: URLRequest) throws -> (Int, String) {
        lock.lock()
        defer { lock.unlock() }
        if offline { throw URLError(.notConnectedToInternet) }
        let path = String(request.url!.path.dropFirst("/api/trpc/".count))
        var raw = request.httpBody
        if raw == nil, let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "input" })?.value {
            raw = Data(q.utf8)
        }
        let input = raw.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?["json"] ?? .null
        calls.append(path)
        if let f = fail[path] { return f }
        let result = handle(path, input)
        if dropAfter == path {
            dropAfter = nil
            throw URLError(.networkConnectionLost)
        }
        if offlineAfter == path {
            offlineAfter = nil
            offline = true
        }
        return result
    }

    private func newId(_ prefix: String) -> String {
        n += 1
        return "new-\(prefix)\(n)"
    }

    private func ok<T: Encodable>(_ v: T) -> (Int, String) {
        let json = String(decoding: try! OfflineStore.encoder().encode(v), as: UTF8.self)
        return (200, #"{"result":{"data":{"json":\#(json)}}}"#)
    }

    private let done = (200, #"{"result":{"data":{"json":null}}}"#)
    private let notFound = (404, #"{"error":{"json":{"message":"NOT_FOUND","data":{"code":"NOT_FOUND","httpStatus":404}}}}"#)

    func front(_ id: String) -> Card? {
        b(id).map { board.lists[$0.index].openCards[$0.cardIndex] }
    }

    private func b(_ id: String) -> (index: Int, cardIndex: Int)? { board.list(containing: id) }

    private func full(_ id: String) -> Card? {
        guard var c = front(id) else { return nil }
        c.checklists = checklists[id] ?? []
        c.comments = comments[id] ?? []
        c.attachments = []
        return c
    }

    private func handle(_ path: String, _ input: JSONValue) -> (Int, String) {
        func s(_ k: String) -> String? { input[k]?.string }
        switch path {
        case "board.get": return ok(board)
        case "card.get": return full(s("id")!).map(ok) ?? notFound

        case "card.create":
            guard let li = board.lists.firstIndex(where: { $0.id == s("listId") }) else { return notFound }
            let c = card(newId("c"), board.lists[li].id, s("title")!)
            if input["afterId"] == .null { board.lists[li].cards!.insert(c, at: 0) } else { board.lists[li].cards!.append(c) }
            return ok(c)

        case "card.update":
            guard let (li, ci) = b(s("id")!) else { return notFound }
            if let c = input["coverColor"] { board.lists[li].cards![ci].coverColor = c.string; if c != .null { board.lists[li].cards![ci].coverAttachmentId = nil } }
            if let a = input["coverAttachmentId"] { board.lists[li].cards![ci].coverAttachmentId = a.string; if a != .null { board.lists[li].cards![ci].coverColor = nil } }
            if let t = s("title") { board.lists[li].cards![ci].title = t }
            if let d = s("description") { board.lists[li].cards![ci].description = d }
            if case .bool(let v)? = input["dueComplete"] { board.lists[li].cards![ci].dueComplete = v }
            return ok(board.lists[li].cards![ci])

        case "card.move":
            guard let (li, ci) = b(s("id")!), let ti = board.lists.firstIndex(where: { $0.id == s("listId") }) else { return notFound }
            var c = board.lists[li].cards!.remove(at: ci)
            c.listId = board.lists[ti].id
            // Like the server's posAfter: null = top, an unknown id = the end.
            let target = board.lists[ti].openCards
            let at = s("afterId").map { a in target.firstIndex { $0.id == a }.map { $0 + 1 } ?? target.count } ?? 0
            board.lists[ti].cards!.insert(c, at: at)
            return ok(c)

        case "card.toggleLabel":
            guard let (li, ci) = b(s("id")!) else { return notFound }
            Change.setLabel(cardId: s("id")!, label: board.label(s("labelId")!)!, on: input["on"] == .bool(true), was: false)
                .apply(to: &board.lists[li].cards![ci])
            return done

        case "list.create":
            let l = BoardList(id: newId("l"), boardId: board.id, name: s("name")!, pos: "", color: nil, closed: false, cards: [])
            board.lists.append(l)
            return ok(l)

        case "card.addChecklist":
            guard front(s("id")!) != nil else { return notFound }
            let k = Checklist(id: newId("k"), cardId: s("id")!, name: s("name")!, pos: "", items: [])
            checklists[k.cardId, default: []].append(k)
            return ok(k)

        case "card.addCheckItem":
            for (cardId, lists) in checklists {
                if let i = lists.firstIndex(where: { $0.id == s("checklistId") }) {
                    let item = CheckItem(id: newId("i"), checklistId: lists[i].id, name: s("name")!, pos: "", complete: false, due: nil, memberId: nil, member: nil)
                    checklists[cardId]![i].items.append(item)
                    return done
                }
            }
            return (500, #"{"error":{"json":{"message":"No Checklist found","data":{"code":"INTERNAL_SERVER_ERROR","httpStatus":500}}}}"#)

        case "card.updateCheckItem":
            for (cardId, lists) in checklists {
                for (ci, l) in lists.enumerated() {
                    if let ii = l.items.firstIndex(where: { $0.id == s("itemId") }) {
                        if case .bool(let v)? = input["complete"] { checklists[cardId]![ci].items[ii].complete = v }
                        return done
                    }
                }
            }
            return (500, #"{"error":{"json":{"message":"No CheckItem found","data":{"code":"INTERNAL_SERVER_ERROR","httpStatus":500}}}}"#)

        case "card.addComment":
            guard front(s("id")!) != nil else { return notFound }
            let m = Comment(id: newId("m"), cardId: s("id")!, authorId: me.id, text: s("text")!, createdAt: Date(), editedAt: nil, author: me)
            comments[m.cardId, default: []].insert(m, at: 0)
            return ok(m)

        case "card.deleteComment":
            for (cardId, list) in comments where list.contains(where: { $0.id == s("commentId") }) {
                comments[cardId]!.removeAll { $0.id == s("commentId") }
                return done
            }
            return (500, #"{"error":{"json":{"message":"No Comment found","data":{"code":"INTERNAL_SERVER_ERROR","httpStatus":500}}}}"#)

        default:
            return (400, #"{"error":{"json":{"message":"unknown \#(path)","data":{"code":"BAD_REQUEST","httpStatus":400}}}}"#)
        }
    }

    func count(_ path: String) -> Int { calls.filter { $0 == path }.count }
}

final class ReplayTests: XCTestCase {
    var server: FakeHackban!
    var replayer: Replayer!

    override func setUp() {
        server = FakeHackban()
        let creds = AccountCredentials(clientId: "c", tokenEndpoint: URL(string: "https://h.com/api/oauth/token")!,
                                       tokens: OAuthTokens(accessToken: "t", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), scope: "app"))
        let tokens = TokenManager(credentials: creds, http: server) { _ in }
        replayer = Replayer(api: HackbanAPI(client: TRPCClient(server: URL(string: "https://h.com")!, tokens: tokens, http: server)), me: me.id)
    }

    /// What the app's sync engine does: send changes in order, keeping the snapshot up to date.
    @discardableResult
    func drain(_ q: inout OfflineQueue, snapshot: inout Board?, card: Card? = nil) async -> [SyncStep] {
        var steps: [SyncStep] = []
        let snap = snapshot
        while let (op, inDoubt) = q.prepareNext(replayer: replayer, snapshots: { _ in (snap, card) }) {
            let result: Result<Replayer.Outcome, Error>
            do {
                result = .success(try await replayer.run(op, inDoubt: inDoubt, board: snapshot, card: card, mapped: Set(q.ids.values)))
            } catch {
                result = .failure(error)
            }
            let step = q.finish(op, result)
            steps.append(step)
            switch step {
            case .synced(_, let applied?), .conflict(_, let applied?): if snapshot != nil { applied.apply(to: &snapshot!) }
            case .offline, .signedOut, .cancelled: return steps
            default: break
            }
        }
        return steps
    }

    func testOfflineSessionReplaysInOrderWithRealIds() async {
        var q = OfflineQueue(userId: me.id)
        let changes: [Change] = [
            .createList(id: "local:l", name: "Doing"),
            .createCard(id: "local:c", listId: "local:l", title: "Draft", atTop: false),
            .updateCard(id: "local:c", patch: .init(title: "Draft v2"), base: .init(title: "Draft")),
            .moveCard(id: "c1", listId: "local:l", above: ["local:c"]),
            .setLabel(cardId: "c2", label: urgent, on: true, was: false),
            .addChecklist(id: "local:k", cardId: "local:c", name: "Steps"),
            .addCheckItem(id: "local:i", cardId: "local:c", checklistId: "local:k", name: "One"),
            .updateCheckItem(id: "local:i", cardId: "local:c", patch: .init(complete: true), base: .init(complete: false)),
            .addComment(id: "local:m", cardId: "local:c", text: "hi", author: me, at: Date()),
            .updateCard(id: "c2", patch: .init(description: "new"), base: .init(description: "")),
        ]
        // What you'd see while offline.
        var shown = server.board
        for c in changes {
            q.enqueue(op(c))
            c.apply(to: &shown)
        }
        XCTAssertEqual(q.pending.count, 9)
        XCTAssertEqual(ids(shown, "local:l"), ["local:c", "c1"])

        var snapshot: Board? = server.board
        server.offline = true
        let first = await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(first, [.offline])
        XCTAssertEqual(q.pending.count, 9)
        XCTAssertNil(q.pending[0].sentAt, "never reached the server, so no lookup next time")

        server.offline = false
        let steps = await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(steps.count, 9)
        XCTAssertTrue(q.isEmpty)

        let list = server.board.lists.first { $0.name == "Doing" }!
        XCTAssertEqual(list.openCards.map(\.title), ["Draft v2", "Write post"])
        let draft = list.openCards[0]
        XCTAssertEqual(q.ids["local:c"], draft.id)
        XCTAssertEqual(server.front("c2")?.labelIds, ["l1"])
        XCTAssertEqual(server.front("c2")?.description, "new")
        XCTAssertEqual(server.checklists[draft.id]?.first?.items.map(\.complete), [true])
        XCTAssertEqual(server.comments[draft.id]?.map(\.text), ["hi"])
        // One of each create, no retries.
        XCTAssertEqual(server.count("list.create"), 1)
        XCTAssertEqual(server.count("card.create"), 1)
        XCTAssertEqual(server.count("card.addCheckItem"), 1)
        XCTAssertEqual(server.count("card.addComment"), 1)
        // The snapshot kept up: it matches the server apart from server-made fields.
        XCTAssertEqual(ids(snapshot!, list.id), list.openCards.map(\.id))
    }

    func testCreateWhoseAnswerWasLostIsFoundNotRepeated() async {
        var q = OfflineQueue(userId: me.id)
        q.enqueue(op(.createCard(id: "local:c", listId: "li2", title: "Draft", atTop: false)))
        q.enqueue(op(.setLabel(cardId: "local:c", label: urgent, on: true, was: false)))
        var snapshot: Board? = server.board

        server.dropAfter = "card.create"
        let first = await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(first, [.offline])
        XCTAssertNotNil(q.pending[0].sentAt, "it may have arrived")

        await drain(&q, snapshot: &snapshot)
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(server.count("card.create"), 1)
        let cards = server.board.lists[1].openCards
        XCTAssertEqual(cards.map(\.title), ["Draft"])
        XCTAssertEqual(cards[0].labelIds, ["l1"])
        XCTAssertEqual(q.ids["local:c"], cards[0].id)
    }

    func testLostAnswerDoesntAdoptALookAlikeThatWasAlreadyThere() async {
        server.board.lists[1].cards = [card("old", "li2", "Draft")]
        var q = OfflineQueue(userId: me.id)
        q.enqueue(op(.createCard(id: "local:c", listId: "li2", title: "Draft", atTop: false)))
        var snapshot: Board? = server.board
        server.offline = false
        server.dropAfter = "card.create"
        await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(q.pending[0].existing, ["old"])
        await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(server.count("card.create"), 1)
        XCTAssertNotEqual(q.ids["local:c"], "old")
        XCTAssertEqual(server.board.lists[1].openCards.count, 2)
    }

    func testNewIdThatCouldntBeFetchedIsLookedForNotRecreated() async {
        server.checklists["c1"] = [Checklist(id: "k1", cardId: "c1", name: "Steps", pos: "a0", items: [])]
        var q = OfflineQueue(userId: me.id)
        q.enqueue(op(.addCheckItem(id: "local:i", cardId: "c1", checklistId: "k1", name: "One")))
        q.enqueue(op(.updateCheckItem(id: "local:i", cardId: "c1", patch: .init(complete: true), base: .init(complete: false))))
        var snapshot: Board? = server.board
        // The item is made, then the network goes before its id can be fetched.
        server.offlineAfter = "card.addCheckItem"
        let first = await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(first, [.offline])
        XCTAssertNotNil(q.pending[0].sentAt)

        // Still offline when the retry looks for it: it stays in doubt rather than being made again.
        _ = await drain(&q, snapshot: &snapshot)
        XCTAssertNotNil(q.pending[0].sentAt)

        server.offline = false
        await drain(&q, snapshot: &snapshot)
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(server.count("card.addCheckItem"), 1)
        XCTAssertEqual(server.checklists["c1"]?[0].items.map(\.complete), [true])
    }

    func testRepeatingCardThatAlreadyRolledIsntCompletedAgain() async {
        var c = server.board.lists[0].cards![0]
        c.recurrence = "weekly"
        c.due = Date(timeIntervalSince1970: 1_800_000_000)
        server.board.lists[0].cards![0] = c
        let patch = HackbanAPI.CardPatch(dueComplete: true)
        var q = OfflineQueue(userId: me.id)
        q.enqueue(op(.updateCard(id: "c1", patch: patch, base: patch.base(from: c))))
        // The completion reached the server but its answer didn't: it has already moved on a week.
        server.board.lists[0].cards![0].due = c.due!.addingTimeInterval(7 * 86_400)
        var snapshot: Board? = server.board
        await drain(&q, snapshot: &snapshot)
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(server.count("card.update"), 0)
    }

    func testTitleConflictKeepsTheirsAndSendsTheRest() async {
        var q = OfflineQueue(userId: me.id)
        q.enqueue(op(.updateCard(id: "c1", patch: .init(title: "Mine", dueComplete: true), base: .init(title: "Write post", dueComplete: false))))
        // Someone renamed it while we were offline; we refetch before replaying.
        server.board.lists[0].cards![0].title = "Theirs"
        var snapshot: Board? = server.board
        let steps = await drain(&q, snapshot: &snapshot)
        guard case .conflict = steps.first else { return XCTFail("\(steps)") }
        XCTAssertEqual(server.front("c1")?.title, "Theirs")
        XCTAssertEqual(server.front("c1")?.dueComplete, true)
        XCTAssertEqual(q.failed.first?.conflicts, [FieldConflict(field: "title", theirs: "Theirs", mine: "Mine")])

        q.retry(q.failed[0].id, useMine: true)
        await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(server.front("c1")?.title, "Mine")
        XCTAssertTrue(q.isEmpty)
    }

    func testMoveIsReresolvedAgainstTheLiveList() async {
        var q = OfflineQueue(userId: me.id)
        // Dropped under c2 at the top of Done, but someone else since deleted c2.
        q.enqueue(op(.moveCard(id: "c3", listId: "li1", above: ["c2", "c1"])))
        server.board.lists[0].cards!.remove(at: 1)
        var snapshot: Board? = server.board
        await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(ids(server.board, "li1"), ["c1", "c3"])
    }

    func testChangesToThingsDeletedOnTheServerFailWithAReason() async {
        var q = OfflineQueue(userId: me.id)
        q.enqueue(op(.createCard(id: "local:c", listId: "li2", title: "Draft", atTop: false)))
        q.enqueue(op(.setLabel(cardId: "local:c", label: urgent, on: true, was: false)))
        q.enqueue(op(.updateCard(id: "c1", patch: .init(title: "Mine"), base: .init(title: "Write post"))))
        q.enqueue(op(.deleteComment(id: "m-gone", cardId: "c2")))
        q.enqueue(op(.moveCard(id: "c2", listId: "li2", above: [])))
        server.board.lists[1].closed = true
        server.board.lists.remove(at: 1)
        server.board.lists[0].cards!.remove(at: 0)
        var snapshot: Board? = server.board
        await drain(&q, snapshot: &snapshot)
        XCTAssertTrue(q.pending.isEmpty)
        XCTAssertEqual(q.failed.map(\.reason), [
            "The list was deleted or archived by someone else.",
            "It needs something else that couldn't sync.",
            "The card was deleted, or you no longer have access to it.",
            "The list it was moved to was deleted or archived by someone else.",
        ])
        // Deleting a comment that's already gone is done, not failed.
        XCTAssertEqual(server.count("card.deleteComment"), 1)
    }

    func testServerTroubleRetriesThenGivesUpWithoutBlockingTheRest() async {
        var q = OfflineQueue(userId: me.id)
        q.enqueue(op(.updateCard(id: "c1", patch: .init(description: "x"), base: .init(description: ""))))
        q.enqueue(op(.updateCard(id: "c2", patch: .init(description: "y"), base: .init(description: ""))))
        server.fail["card.update"] = (500, #"{"error":{"json":{"message":"Database hiccup","data":{"code":"INTERNAL_SERVER_ERROR","httpStatus":500}}}}"#)
        var snapshot: Board? = server.board
        let steps = await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(steps.prefix(3).map { if case .retry = $0 { return true } else { return false } }, [true, true, false])
        XCTAssertEqual(q.failed.first?.reason, "Database hiccup")
        XCTAssertEqual(q.failed.count, 2)

        server.fail["card.update"] = (502, "<html>Bad gateway</html>")
        q.retry(q.failed[0].id)
        let offline = await drain(&q, snapshot: &snapshot)
        XCTAssertEqual(offline, [.offline])
        XCTAssertEqual(q.pending.count, 1)
    }
}

final class IdentityGateTests: XCTestCase {
    func testNothingIsSentUntilTheCurrentTokensAreConfirmed() {
        // At launch the cached profile says who this is, but that's not confirmed with the tokens.
        var g = IdentityGate(cacheOwner: "u1")
        XCTAssertEqual(g.send(madeBy: "u1"), .hold)
        XCTAssertTrue(g.showsCache, "offline at launch, what's kept still shows")
        XCTAssertEqual(g.confirm("u1", generation: g.generation), .same)
        XCTAssertEqual(g.send(madeBy: "u1"), .send)
    }

    func testChangesWithNoKnownMakerAreNeverSent() {
        var g = IdentityGate()
        XCTAssertEqual(g.send(madeBy: nil), .hold)
        g.confirm("u1", generation: g.generation)
        XCTAssertEqual(g.send(madeBy: nil), .unknownMaker)
    }

    func testChangesMadeAsSomeoneElseAreNeverSent() {
        var g = IdentityGate(cacheOwner: "u1")
        g.confirm("u1", generation: g.generation)
        XCTAssertEqual(g.send(madeBy: "u2"), .wrongUser)
    }

    func testANewSignInHidesAndHoldsUntilConfirmed() {
        var g = IdentityGate(cacheOwner: "u1")
        g.confirm("u1", generation: g.generation)
        g.beginSignIn()
        // The old confirmation (and the cached id) no longer count.
        XCTAssertNil(g.verified)
        XCTAssertEqual(g.send(madeBy: "u1"), .hold)
        XCTAssertFalse(g.showsCache)
        // Couldn't confirm (offline, server error): still held and hidden.
        XCTAssertEqual(g.send(madeBy: "u1"), .hold)
        XCTAssertFalse(g.showsCache)
        XCTAssertEqual(g.confirm("u1", generation: g.generation), .same)
        XCTAssertTrue(g.showsCache)
        XCTAssertEqual(g.send(madeBy: "u1"), .send)
    }

    func testSigningInAsSomeoneElseForgetsTheCache() {
        var g = IdentityGate(cacheOwner: "u1")
        g.beginSignIn()
        XCTAssertEqual(g.confirm("u2", generation: g.generation), .someoneElse)
        XCTAssertEqual(g.send(madeBy: "u1"), .wrongUser)
        XCTAssertEqual(g.send(madeBy: "u2"), .send)
    }

    func testANewSignInOverDataOfUnknownOwnershipForgetsIt() {
        var g = IdentityGate()
        g.beginSignIn()
        XCTAssertEqual(g.confirm("u2", generation: g.generation), .someoneElse)
        // A brand new account with nothing kept has nothing to forget.
        var fresh = IdentityGate()
        XCTAssertEqual(fresh.confirm("u2", generation: fresh.generation), .same)
    }

    func testAConfirmationForSomeoneElseWithoutASignInStillCounts() {
        // The tokens changed under us somehow: the data kept for the old user isn't the new one's.
        var g = IdentityGate(cacheOwner: "u1")
        g.confirm("u1", generation: g.generation)
        XCTAssertEqual(g.confirm("u2", generation: g.generation), .someoneElse)
    }

    func testSigningOutForgetsEverything() {
        var g = IdentityGate(cacheOwner: "u1")
        g.confirm("u1", generation: g.generation)
        g.reset()
        XCTAssertNil(g.verified)
        XCTAssertNil(g.cacheOwner)
        XCTAssertEqual(g.send(madeBy: "u1"), .hold)
    }

    func testAProfileFetchedWithOldTokensConfirmsNothing() {
        var g = IdentityGate(cacheOwner: "u1")
        // A refresh sets off with the old tokens…
        let before = g.generation
        // …and while it's out, someone signs in again.
        g.beginSignIn()
        XCTAssertNil(g.confirm("u1", generation: before), "fetched before the sign-in started")
        let between = g.generation
        g.tokensInstalled()
        XCTAssertNil(g.confirm("u1", generation: between), "fetched before the new tokens went in")
        XCTAssertEqual(g.send(madeBy: "u1"), .hold)
        XCTAssertFalse(g.showsCache)
        XCTAssertEqual(g.confirm("u2", generation: g.generation), .someoneElse)
        XCTAssertEqual(g.send(madeBy: "u1"), .wrongUser)
    }

    func testAnUnconfirmedSignInSurvivesARelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hackban-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OfflineStore(root: dir)
        XCTAssertFalse(store.isSigningIn)
        try store.markSigningIn()
        // Relaunch: the gate starts hidden and held again.
        let relaunched = OfflineStore(root: dir)
        XCTAssertTrue(relaunched.isSigningIn)
        var g = IdentityGate(cacheOwner: "u1")
        g.resumeSignIn()
        XCTAssertFalse(g.showsCache)
        XCTAssertEqual(g.send(madeBy: "u1"), .hold)
        relaunched.clearSigningIn()
        XCTAssertFalse(store.isSigningIn)
    }
}
