import Foundation
import HackbanKit
import Observation

/// The full card shown in the card sheet.
///
/// Like a board, the card comes from the account's `SyncEngine`: its last `card.get` (or, if it was never
/// opened, its front on the board) with changes still waiting to sync on top.
@MainActor
@Observable
final class CardModel {
    let app: AppModel
    let account: Account
    /// The id it was opened with. A card made offline keeps its temporary id here; `id` follows it to the
    /// server's once it syncs.
    let cardId: String
    /// The open board this card is on, if it's loaded, so card-front changes show up immediately.
    var boardModel: BoardModel?

    var loadError: String?
    var uploading = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    var api: HackbanAPI { account.api }
    var sync: SyncEngine { account.sync }
    var id: String { sync.resolve(cardId) }
    var card: Card? { sync.card(cardId) }
    var boardId: String? { card?.list?.boardId ?? boardModel?.boardId }
    /// Its checklists, comments and attachments haven't been downloaded: it's only known from its board.
    var detailsMissing: Bool { !sync.hasDetails(cardId) }

    init(app: AppModel, account: Account, cardId: String) {
        self.app = app
        self.account = account
        self.cardId = cardId
    }

    static let notDownloaded = "This card hasn't been downloaded yet. It'll open when you're back online."

    func load() async {
        sync.loadCachedCard(id)
        attachBoard()
        // Made offline and not on the server yet: there's nothing more to fetch.
        if TempID.isTemp(id) { return }
        guard !sync.isOffline else {
            if card == nil { loadError = Self.notDownloaded }
            return
        }
        let started = Date()
        do {
            sync.store(card: try await api.card(id), fetchStarted: started)
            loadError = nil
            attachBoard()
            if let bm = boardModel, bm.board == nil { await bm.load() }
        } catch {
            account.handle(error)
            if card == nil { loadError = sync.isOffline ? Self.notDownloaded : error.localizedDescription }
        }
    }

    private func attachBoard() {
        guard boardModel == nil, let bid = card?.list?.boardId ?? sync.boardId(containing: id) else { return }
        let bm = app.boardModel(account: account, boardId: bid)
        boardModel = bm
        bm.openCard = self
        sync.loadCachedBoard(bid)
    }

    func scheduleReload(after ms: UInt64 = 200) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    /// Queue a change that works offline.
    private func perform(_ change: Change) {
        guard let bid = boardId else { return }
        sync.perform(change, board: bid)
    }

    /// A change that needs a connection: send it, then refetch this card and its board.
    private func mutate(_ remote: @escaping () async throws -> Void) {
        guard app.requireOnline(account) else { return }
        Task {
            do {
                try await remote()
            } catch {
                account.handle(error)
                app.flash(app.message(for: error))
            }
            scheduleReload(after: 100)
            boardModel?.scheduleReload()
        }
    }

    // MARK: fields

    func update(_ patch: HackbanAPI.CardPatch) {
        guard let bid = boardId else { return }
        sync.updateCard(cardId, patch, board: bid)
    }

    func toggleLabel(_ label: Label) {
        let on = !(card?.labelIds.contains(label.id) ?? false)
        perform(.setLabel(cardId: id, label: label, on: on, was: !on))
    }

    func toggleMember(_ user: User) {
        let on = !(card?.memberIds.contains(user.id) ?? false)
        perform(.setMember(cardId: id, user: user, on: on, was: !on))
    }

    func toggleWatch() {
        let on = !(card?.watching ?? false)
        perform(.watch(cardId: id, on: on, was: !on))
    }

    func delete() {
        perform(.deleteCard(id: id))
    }

    func setBlocker(_ blocker: String, on: Bool) {
        mutate { [api, id] in try await api.setBlocker(card: id, blocker: blocker, on: on) }
    }

    // MARK: checklists

    func addChecklist(_ name: String, copyFrom: String? = nil) {
        if let copyFrom {
            // The copy's items get their ids on the server, so copying needs a connection.
            mutate { [api, id] in try await api.addChecklist(card: id, name: name, copyFrom: copyFrom) }
        } else {
            perform(.addChecklist(id: TempID.make(), cardId: id, name: name))
        }
    }

    func renameChecklist(_ checklist: String, _ name: String) {
        perform(.renameChecklist(id: checklist, cardId: id, name: name))
    }

    func deleteChecklist(_ checklist: String) {
        perform(.deleteChecklist(id: checklist, cardId: id))
    }

    func addItem(to checklist: String, _ name: String) {
        perform(.addCheckItem(id: TempID.make(), cardId: id, checklistId: checklist, name: name))
    }

    private func item(_ itemId: String) -> CheckItem? {
        card?.checklists?.lazy.flatMap(\.items).first { $0.id == itemId }
    }

    func updateItem(_ itemId: String, name: String? = nil, complete: Bool? = nil, due: Date?? = nil, member: User?? = nil) {
        guard let current = item(itemId) else { return }
        let patch = CheckItemPatch(name: name, complete: complete, due: due, member: member)
        perform(.updateCheckItem(id: itemId, cardId: id, patch: patch, base: patch.base(from: current)))
    }

    /// Reorder within or between checklists: put `itemId` before `beforeId` in `checklist` (nil = end).
    func moveItem(_ itemId: String, to checklist: String, before beforeId: String?) {
        guard let target = card?.checklists?.first(where: { $0.id == checklist }), itemId != beforeId else { return }
        let others = target.items.map(\.id).filter { $0 != itemId }
        let at = beforeId.flatMap { others.firstIndex(of: $0) } ?? others.count
        perform(.moveCheckItem(id: itemId, cardId: id, checklistId: checklist, above: Anchors.above(at, in: others)))
    }

    func deleteItem(_ itemId: String) {
        perform(.deleteCheckItem(id: itemId, cardId: id))
    }

    // MARK: comments

    func addComment(_ text: String) {
        let me = account.profile?.asUser ?? User(id: account.me ?? "")
        perform(.addComment(id: TempID.make(), cardId: id, text: text, author: me, at: Date()))
    }

    func editComment(_ comment: String, _ text: String) {
        perform(.editComment(id: comment, cardId: id, text: text))
    }

    func deleteComment(_ comment: String) {
        perform(.deleteComment(id: comment, cardId: id))
    }

    // MARK: attachments

    func upload(_ files: [(name: String, mimeType: String, data: Data)]) {
        guard !files.isEmpty else { return }
        guard !sync.isOffline else { app.flash("You're offline. Uploads will work when you're back online."); return }
        guard !TempID.isTemp(id) else { app.flash("This card hasn't synced yet. Try again in a moment."); return }
        let total = files.reduce(0) { $0 + $1.data.count }
        if total > 100 * 1024 * 1024 { app.flash("Uploads must total under 100 MB."); return }
        uploading += 1
        Task {
            defer { uploading -= 1 }
            do {
                for chunk in stride(from: 0, to: files.count, by: 20) {
                    try await api.uploadAttachments(card: id, files: Array(files[chunk..<min(chunk + 20, files.count)]))
                }
            } catch {
                account.handle(error)
                app.flash(app.message(for: error))
            }
            scheduleReload(after: 50)
            boardModel?.scheduleReload()
        }
    }

    func upload(urls: [URL]) {
        guard !sync.isOffline else { app.flash("You're offline. Uploads will work when you're back online."); return }
        var files: [(name: String, mimeType: String, data: Data)] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                files.append((url.lastPathComponent, MimeType.guess(forExtension: url.pathExtension), data))
            }
        }
        upload(files)
    }

    func addLink(_ url: String, name: String?) {
        perform(.addLink(id: TempID.make(), cardId: id, url: url, name: name?.isEmpty == false ? name : nil))
    }

    func renameAttachment(_ attachment: String, _ name: String) {
        perform(.renameAttachment(id: attachment, cardId: id, name: name))
    }

    func deleteAttachment(_ attachment: String) {
        perform(.deleteAttachment(id: attachment, cardId: id))
    }

    /// Download an attachment to a temp file and open it (uploads need auth, links open in the browser).
    func open(_ a: Attachment) async -> URL? {
        if a.isUpload != true { return account.client.resolve(a.url) }
        do {
            let data = try await account.client.download(a.url)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Hackban/\(a.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = (a.name ?? "attachment").replacingOccurrences(of: "/", with: "-")
            let file = dir.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
            try data.write(to: file)
            return file
        } catch {
            account.handle(error)
            app.flash(app.message(for: error))
            return nil
        }
    }
}
