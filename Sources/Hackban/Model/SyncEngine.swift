import Foundation
import HackbanKit
import Observation

/// One account's offline side: what its server last said (kept on disk too), the changes waiting to reach
/// it, and whether it can be reached at all.
///
/// Views read `boards` and `card(_:)`: the last server snapshot with the waiting changes applied on top,
/// recomputed whenever either changes, so a refetch never flickers an edit away. Every edit that can work
/// offline goes through `perform`, online or not, so there's one path and one order. Online, the queue
/// drains straight away; offline, it waits, and the engine probes the server until it answers.
@MainActor
@Observable
final class SyncEngine {
    @ObservationIgnored weak var account: Account?
    @ObservationIgnored let store: OfflineStore
    @ObservationIgnored private let api: HackbanAPI

    private(set) var queue: OfflineQueue
    /// Who changes may be sent as, and whether what's kept here can be shown (see `IdentityGate`).
    private(set) var identity = IdentityGate()
    private(set) var isOffline = false
    private(set) var offlineSince: Date?
    /// Sending queued changes right now.
    private(set) var draining = false
    /// The queue file couldn't be read (it's from a newer version, or damaged) and was moved here.
    private(set) var queueSetAside: URL?

    /// What views show: snapshot + waiting changes, by board id.
    private(set) var boards: [String: Board] = [:]
    /// Full cards (`card.get`) that have been downloaded, with waiting changes applied, by card id.
    private(set) var cards: [String: Card] = [:]
    /// When each board was last fetched.
    private(set) var boardFetchedAt: [String: Date] = [:]
    private(set) var pendingCardIds: Set<String> = []
    private(set) var failedCardIds: Set<String> = []

    @ObservationIgnored private var boardSnapshots: [String: Board] = [:]
    @ObservationIgnored private var cardSnapshots: [String: Card] = [:]
    /// Changes synced in the last couple of minutes, re-applied to a fetch that started before they landed.
    @ObservationIgnored private var recent: [(change: Change, boardId: String, at: Date)] = []
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Draining after coming back online (or at launch), so failures are summed up in one toast at the end.
    @ObservationIgnored private var catchingUp = false
    /// Refetching boards before catching up: nothing is sent until conflict checks can see the latest.
    @ObservationIgnored private var refreshing = false
    /// The change that was going out when the server last stopped answering mid-request. If the server
    /// answers a probe straight after, that change is what's breaking it, and it's counted as a failed try.
    @ObservationIgnored private var droppedOp: String?
    /// For display only: creates that may have reached the server, matched to the look-alike a refetch
    /// brought back, so they don't show twice before they're replayed.
    @ObservationIgnored private var aliases: [String: String] = [:]

    /// The server became reachable (true) or stopped being (false).
    @ObservationIgnored var onConnectivity: ((Bool) -> Void)?
    /// A change reached the server. `refresh`: the board has server-made parts worth refetching.
    @ObservationIgnored var onSynced: ((_ boardId: String, _ cardId: String?, _ refresh: Bool) -> Void)?
    @ObservationIgnored var onMessage: ((String) -> Void)?

    static let maxBoards = 50
    static let maxCards = 500

    static func directory(for accountId: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hackban/Offline/\(accountId)", isDirectory: true)
    }

    init(accountId: String, api: HackbanAPI) {
        self.api = api
        store = OfflineStore(root: Self.directory(for: accountId))
        if let q = store.load(OfflineQueue.self, "queue.json")?.value, q.version == OfflineQueue.formatVersion {
            queue = q
            queue.pruneIds()
        } else {
            queue = OfflineQueue()
            queueSetAside = store.setAside("queue.json")
        }
        store.prune("boards", keep: Self.maxBoards, except: queue.boardIds)
        store.prune("cards", keep: Self.maxCards, except: Set(queue.pending.compactMap(\.change.cardId)))
        for id in queue.boardIds { loadCachedBoard(id) }
        recompute()
    }

    var pendingCount: Int { queue.pending.count }
    var hasFailures: Bool { !queue.failed.isEmpty }
    /// Worth showing a sync status for.
    var hasStatus: Bool { isOffline || !queue.isEmpty || queueSetAside != nil || !identity.showsCache }

    func resolve(_ id: String) -> String { aliases[id] ?? queue.resolve(id) }

    // MARK: snapshots

    func loadCachedBoard(_ id: String) {
        guard boardSnapshots[id] == nil, let (b, at) = store.load(Board.self, OfflineStore.file("boards", id)) else { return }
        boardSnapshots[id] = b
        boardFetchedAt[id] = at
        recompute()
    }

    func loadCachedCard(_ id: String) {
        guard !TempID.isTemp(id), cardSnapshots[id] == nil, let (c, _) = store.load(Card.self, OfflineStore.file("cards", id)) else { return }
        cardSnapshots[id] = c
        recompute()
    }

    /// A fresh `board.get`. Changes that synced after the fetch set off are put back on top.
    func store(board: Board, fetchStarted: Date) {
        var b = board
        for r in recent where r.boardId == board.id && r.at >= fetchStarted { r.change.apply(to: &b) }
        boardSnapshots[b.id] = b
        boardFetchedAt[b.id] = Date()
        store.save(b, OfflineStore.file("boards", b.id))
        recompute()
    }

    func store(card: Card, fetchStarted: Date) {
        var c = card
        for r in recent where r.change.cardId == card.id && r.at >= fetchStarted { r.change.apply(to: &c) }
        cardSnapshots[c.id] = c
        store.save(c, OfflineStore.file("cards", c.id))
        recompute()
    }

    /// For changes that need a connection: applied to the snapshot at once, before the server has them.
    func editSnapshot(_ boardId: String, _ f: (inout Board) -> Void) {
        guard var b = boardSnapshots[boardId] else { return }
        f(&b)
        boardSnapshots[boardId] = b
        recompute()
    }

    /// A card made here has no checklists, comments or attachments yet, so its full card is known: keep
    /// one, so what's added to it shows even before (or without) a fetch.
    private func seedNewCard(_ id: String, board boardId: String) {
        guard cardSnapshots[id] == nil, let b = boardSnapshots[boardId], let (li, ci) = b.list(containing: id) else { return }
        var c = b.lists[li].openCards[ci]
        c.checklists = []
        c.comments = []
        c.attachments = []
        cardSnapshots[id] = c
    }

    private func applyToSnapshots(_ change: Change, board boardId: String) {
        if var b = boardSnapshots[boardId] {
            change.apply(to: &b)
            boardSnapshots[boardId] = b
            store.save(b, OfflineStore.file("boards", boardId))
        }
        if let cid = change.cardId, var c = cardSnapshots[cid] {
            change.apply(to: &c)
            cardSnapshots[cid] = c
            store.save(c, OfflineStore.file("cards", cid))
        }
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0.at) > 120 }
        recent.append((change, boardId, now))
    }

    private func recompute() {
        // A new sign-in that isn't confirmed yet: nothing kept here is shown, it may be someone else's.
        guard identity.showsCache else {
            if !boards.isEmpty { boards = [:] }
            if !cards.isEmpty { cards = [:] }
            if !pendingCardIds.isEmpty { pendingCardIds = [] }
            if !failedCardIds.isEmpty { failedCardIds = [] }
            return
        }
        aliases = inDoubtAliases()
        let ops = queue.pending
            .filter { $0.change.created.map { aliases[$0] == nil } ?? true }
            .map { (boardId: $0.boardId, change: $0.change.mapIds(resolve)) }
        var nb: [String: Board] = [:]
        for (id, snapshot) in boardSnapshots {
            var b = snapshot
            for o in ops where o.boardId == id { o.change.apply(to: &b) }
            nb[id] = b
        }
        if nb != boards { boards = nb }
        var nc: [String: Card] = [:]
        for (id, snapshot) in cardSnapshots {
            var c = snapshot
            for o in ops where o.change.cardId == id { o.change.apply(to: &c) }
            nc[id] = c
        }
        if nc != cards { cards = nc }
        let pending = Set(ops.compactMap(\.change.cardId))
        if pending != pendingCardIds { pendingCardIds = pending }
        let failed = Set(queue.failed.compactMap { $0.op.change.cardId.map(queue.resolve) })
        if failed != failedCardIds { failedCardIds = failed }
    }

    private func inDoubtAliases() -> [String: String] {
        let finder = Replayer(api: api, me: identity.verified)
        let mapped = Set(queue.ids.values)
        var out: [String: String] = [:]
        for op in queue.pending where op.sentAt != nil {
            guard let temp = op.change.created, queue.ids[temp] == nil else { continue }
            let change = queue.resolved(op.change)
            if let found = finder.adopt(change, board: boardSnapshots[op.boardId], card: change.cardId.flatMap { cardSnapshots[$0] },
                                        exclude: mapped.union(op.existing ?? [])) {
                out[temp] = found
            }
        }
        return out
    }

    /// The full card if it's been downloaded, otherwise its front from a board that's loaded.
    func card(_ id: String) -> Card? {
        let id = resolve(id)
        let located = locate(id)
        var c: Card
        if let full = cards[id] {
            c = full
        } else if let (b, li, ci) = located {
            c = b.lists[li].openCards[ci]
            // Never downloaded: checklists, comments and links added here still show.
            for op in queue.pending where op.change.cardId.map(resolve) == id { op.change.mapIds(resolve).apply(to: &c) }
        } else {
            return nil
        }
        // "In list …" follows moves made here.
        if let (b, li, _) = located {
            c.list = ListRef(id: b.lists[li].id, name: b.lists[li].name, boardId: b.id,
                             board: BoardRef(id: b.id, name: b.name, background: b.background, bgImage: b.bgImage))
        }
        return c
    }

    /// Whether the card's checklists, comments and attachments have been downloaded.
    func hasDetails(_ id: String) -> Bool { cards[resolve(id)] != nil || TempID.isTemp(resolve(id)) }

    func boardId(containing cardId: String) -> String? { locate(resolve(cardId))?.0.id }

    private func locate(_ cardId: String) -> (Board, Int, Int)? {
        for b in boards.values {
            if let (li, ci) = b.list(containing: cardId) { return (b, li, ci) }
        }
        return nil
    }

    // MARK: changes

    func perform(_ change: Change, board boardId: String) {
        if queue.isEmpty || queue.userId == nil { queue.userId = identity.verified ?? account?.me }
        queue.enqueue(PendingOp(boardId: boardId, change: queue.resolved(change)))
        saveQueue()
        recompute()
        drain()
    }

    /// A card edit, with the base its conflict check compares against.
    func updateCard(_ id: String, _ patch: HackbanAPI.CardPatch, board boardId: String) {
        guard let current = card(id) else { return }
        perform(.updateCard(id: resolve(id), patch: patch, base: patch.base(from: current)), board: boardId)
    }

    private func saveQueue() {
        do { try store.write(queue, "queue.json") } catch { onMessage?("Couldn't save changes waiting to sync: \(error.localizedDescription)") }
    }

    func retry(_ failedId: String, useMine: Bool = false) {
        queue.retry(failedId, useMine: useMine)
        saveQueue()
        recompute()
        drain()
    }

    func discard(_ failedId: String) {
        queue.discard(failedId)
        saveQueue()
        recompute()
    }

    func dismissSetAside() { queueSetAside = nil }

    /// A few words about a queued change, using the names you'd recognise.
    func describe(_ op: PendingOp) -> String {
        let change = queue.resolved(op.change)
        var title: String?
        if let cid = change.cardId {
            title = card(cid)?.title
            if title == nil, case .createCard(_, _, let t, _) = change { title = t }
        } else {
            title = boards[op.boardId]?.lists.first { $0.id == change.subject }?.name
        }
        return change.describe(title)
    }

    // MARK: sending

    func drain() {
        guard !draining, !refreshing, !isOffline, let account, !account.signedOut, queue.next != nil else { return }
        draining = true
        Task {
            await runQueue()
            draining = false
            // Something may have been queued as the last change finished.
            if !isOffline, queue.next != nil, account.signedOut == false { drain() }
        }
    }

    private func runQueue() async {
        guard let account else { return }
        let failedBefore = queue.failed.count
        loop: while !isOffline, !account.signedOut {
            // Checked before every change: a sign-in can start while the queue drains.
            switch identity.send(madeBy: queue.userId) {
            case .send:
                break
            case .hold:
                break loop
            case .wrongUser:
                refuseAll("These changes were made while signed in as someone else, so they weren't sent.")
                break loop
            case .unknownMaker:
                refuseAll("It isn't known which account made these changes, so they weren't sent.")
                break loop
            }
            let replayer = Replayer(api: api, me: identity.verified)
            let boardSnaps = boardSnapshots, cardSnaps = cardSnapshots
            guard let (op, inDoubt) = queue.prepareNext(replayer: replayer, snapshots: { o in
                (boardSnaps[o.boardId], o.change.cardId.flatMap { cardSnaps[$0] })
            }) else { break }
            // A create is on disk as sent before it goes out, so a crash can't make it twice.
            saveQueue()
            let result: Result<Replayer.Outcome, Error>
            do {
                let card = op.change.cardId.flatMap { cardSnapshots[$0] }
                result = .success(try await replayer.run(op, inDoubt: inDoubt, board: boardSnapshots[op.boardId], card: card, mapped: Set(queue.ids.values)))
            } catch {
                result = .failure(error)
            }
            let step = queue.finish(op, result)
            if case .failure(let e) = result, Reachability.classify(e) == .offline, Reachability.mayHaveReachedServer(e) { droppedOp = op.id } else { droppedOp = nil }
            saveQueue()
            switch step {
            case .synced(let op, let applied):
                if let applied {
                    applyToSnapshots(applied, board: op.boardId)
                    if case .createCard(let id, _, _, _) = applied { seedNewCard(id, board: op.boardId) }
                }
                onSynced?(op.boardId, applied?.cardId ?? op.change.cardId, op.change.refreshesBoard || applied == nil)
            case .conflict(let op, let applied):
                if let applied { applyToSnapshots(applied, board: op.boardId) }
                onSynced?(op.boardId, op.change.cardId, false)
                if !catchingUp { onMessage?("Someone else edited \(describe(op).lowercased()) at the same time. Pick a version from the sync status.") }
            case .failed(let op, let reason):
                if !catchingUp { onMessage?(reason) }
                onSynced?(op.boardId, op.change.cardId, true)
            case .offline:
                goOffline()
            case .retry(let after):
                recompute()
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            case .signedOut:
                account.handle(HackbanError.signedOut)
            case .cancelled:
                break loop
            }
            recompute()
        }
        if catchingUp, !isOffline, queue.next == nil {
            catchingUp = false
            let n = queue.failed.count - failedBefore
            if n > 0 { onMessage?(n == 1 ? "1 change couldn't sync. The sync status has the details." : "\(n) changes couldn't sync. The sync status has the details.") }
        }
    }

    private func refuseAll(_ reason: String) {
        queue.failAll(reason: reason)
        saveQueue()
        recompute()
    }

    // MARK: identity

    /// Whose data is kept here, as far as is known (from the cached profile, or the queue).
    func setCacheOwner(_ userId: String?) { identity.cacheOwner = userId }

    /// New tokens are about to be installed: hide what's kept and send nothing until they're confirmed.
    func beginSignIn() {
        identity.beginSignIn()
        recompute()
    }

    /// A profile fetched with the current tokens says who this is. The caller forgets what's kept if it
    /// was someone else's, then lets the queue go.
    func confirm(_ userId: String) -> IdentityGate.Confirmed {
        let result = identity.confirm(userId)
        recompute()
        return result
    }

    /// Signed out on purpose.
    func forgetIdentity() {
        identity.reset()
        recompute()
    }

    /// At launch or after signing in again: catch up on whatever's waiting.
    func resume() {
        guard queue.next != nil, !isOffline, !refreshing else { return }
        catchingUp = true
        refreshing = true
        Task {
            await refreshBoardsWithChanges()
            refreshing = false
            drain()
        }
    }

    /// Fresh snapshots of the boards with waiting changes, so the conflict checks see what others did.
    private func refreshBoardsWithChanges() async {
        for id in queue.boardIds {
            let started = Date()
            do {
                store(board: try await api.board(id), fetchStarted: started)
            } catch {
                switch Reachability.classify(error) {
                case .offline:
                    goOffline()
                    return
                case .rejected:
                    if case .server(let code, _, _)? = error as? HackbanError, code == "NOT_FOUND" || code == "FORBIDDEN" {
                        queue.failAll(reason: "The board was deleted, or you no longer have access to it.") { $0.boardId == id }
                        saveQueue()
                        recompute()
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: connectivity

    func goOffline() {
        catchingUp = false
        guard !isOffline else { return }
        isOffline = true
        offlineSince = Date()
        onConnectivity?(false)
        probe(after: 2)
    }

    /// The network came back or the app came to the front: check now rather than at the next backoff.
    func probeNow() {
        if isOffline { probe(after: 0) }
    }

    private func probe(after first: Double) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            var delay = first
            while !Task.isCancelled {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard let self, self.isOffline, !Task.isCancelled else { return }
                do {
                    // Reachable again, and this confirms who the tokens belong to.
                    let profile = try await self.api.profile()
                    self.account?.confirmIdentity(profile.id)
                    self.cameOnline()
                    return
                } catch {
                    if Reachability.classify(error) == .signedOut {
                        // Reachable, just signed out: stop probing; signing in again resumes.
                        self.account?.handle(error)
                        self.cameOnline()
                        return
                    }
                }
                delay = min(max(delay * 2, 2), 60)
            }
        }
    }

    private func cameOnline() {
        probeTask?.cancel()
        probeTask = nil
        isOffline = false
        offlineSince = nil
        // The server answers, yet the last change sent lost its connection: it may be what's breaking it.
        // After a few rounds of that, set it aside so the rest can sync.
        if let id = droppedOp, queue.next?.id == id {
            if queue.noteAttempt(id) >= OfflineQueue.maxAttempts {
                queue.fail(id, reason: "The connection kept dropping while this was being sent. It may or may not have reached the server.")
            }
            saveQueue()
            recompute()
        }
        droppedOp = nil
        onConnectivity?(true)
        resume()
    }

    /// Signing out of the account for good: forget everything on disk.
    func wipe() {
        store.removeAll()
        queue = OfflineQueue()
        queueSetAside = nil
        boardSnapshots = [:]
        cardSnapshots = [:]
        boardFetchedAt = [:]
        recent = []
        recompute()
    }
}
