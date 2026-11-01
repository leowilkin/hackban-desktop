import Foundation
import HackbanKit
import Observation

/// The full card shown in the card sheet.
@MainActor
@Observable
final class CardModel {
    let app: AppModel
    let account: Account
    let cardId: String
    /// The open board this card is on, if it's loaded, so card-front changes show up immediately.
    var boardModel: BoardModel?

    var card: Card?
    var loadError: String?
    var uploading = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    var api: HackbanAPI { account.api }
    var boardId: String? { card?.list?.boardId }

    init(app: AppModel, account: Account, cardId: String) {
        self.app = app
        self.account = account
        self.cardId = cardId
    }

    func load() async {
        do {
            let c = try await api.card(cardId)
            card = c
            loadError = nil
            if boardModel == nil, let bid = c.list?.boardId {
                let bm = app.boardModel(account: account, boardId: bid)
                boardModel = bm
                bm.openCard = self
                if bm.board == nil { await bm.load() }
            }
        } catch {
            account.handle(error)
            loadError = error.localizedDescription
        }
    }

    func scheduleReload(after ms: UInt64 = 200) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func applyLocal(_ patch: HackbanAPI.CardPatch) {
        guard var c = card else { return }
        patch.apply(to: &c)
        card = c
    }

    /// Mutate locally, send, then reload this card (and the board, which skips our own echo).
    func mutate(_ local: (inout Card) -> Void = { _ in }, reloadBoard: Bool = true, _ remote: @escaping () async throws -> Void) {
        if var c = card {
            local(&c)
            card = c
        }
        Task {
            do {
                try await remote()
            } catch {
                account.handle(error)
                app.flash(error.localizedDescription)
            }
            scheduleReload(after: 100)
            if reloadBoard { boardModel?.scheduleReload() }
        }
    }

    // MARK: fields (routed through the board so card fronts update too)

    func update(_ patch: HackbanAPI.CardPatch) {
        if let bm = boardModel, bm.card(cardId) != nil || patch.closed == false {
            bm.updateCard(cardId, patch)
            if patch.closed == false { bm.scheduleReload() }
            scheduleReload(after: 300)
        } else {
            mutate({ patch.apply(to: &$0) }) { [api, cardId] in try await api.updateCard(cardId, patch) }
        }
    }

    func toggleLabel(_ label: Label) {
        if let bm = boardModel, bm.card(cardId) != nil {
            bm.toggleLabel(card: cardId, label: label)
            let on = !(card?.labelIds.contains(label.id) ?? false)
            if on { card?.labels = (card?.labels ?? []) + [CardLabel(cardId: cardId, labelId: label.id, label: label)] }
            else { card?.labels?.removeAll { $0.labelId == label.id } }
        } else {
            let on = !(card?.labelIds.contains(label.id) ?? false)
            mutate { [api, cardId] in try await api.toggleLabel(card: cardId, label: label.id, on: on) }
        }
    }

    func toggleMember(_ user: User) {
        let on = !(card?.memberIds.contains(user.id) ?? false)
        if on { card?.members = (card?.members ?? []) + [CardMember(cardId: cardId, userId: user.id, user: user)] }
        else { card?.members?.removeAll { $0.userId == user.id } }
        if let bm = boardModel, bm.card(cardId) != nil { bm.toggleMember(card: cardId, user: user) }
        else { mutate { [api, cardId] in try await api.toggleMember(card: cardId, user: user.id, on: on) } }
    }

    func toggleWatch() {
        let on = !(card?.watching ?? false)
        mutate({ $0.watching = on }) { [api, cardId] in try await api.watchCard(cardId, on) }
    }

    func setBlocker(_ blocker: String, on: Bool) {
        mutate { [api, cardId] in try await api.setBlocker(card: cardId, blocker: blocker, on: on) }
    }

    // MARK: checklists

    func addChecklist(_ name: String, copyFrom: String? = nil) {
        mutate { [api, cardId] in try await api.addChecklist(card: cardId, name: name, copyFrom: copyFrom) }
    }

    func renameChecklist(_ id: String, _ name: String) {
        mutate({ c in if let i = c.checklists?.firstIndex(where: { $0.id == id }) { c.checklists![i].name = name } }) { [api] in
            try await api.renameChecklist(id, name: name)
        }
    }

    func deleteChecklist(_ id: String) {
        mutate({ $0.checklists?.removeAll { $0.id == id } }) { [api] in try await api.deleteChecklist(id) }
    }

    func addItem(to checklist: String, _ name: String) {
        mutate { [api] in try await api.addCheckItem(checklist: checklist, name: name) }
    }

    private func editItem(_ id: String, _ c: inout Card, _ f: (inout CheckItem) -> Void) {
        guard let cls = c.checklists else { return }
        for (ci, cl) in cls.enumerated() {
            if let ii = cl.items.firstIndex(where: { $0.id == id }) { f(&c.checklists![ci].items[ii]) }
        }
    }

    func updateItem(_ id: String, name: String? = nil, complete: Bool? = nil, due: Date?? = nil, member: User?? = nil) {
        mutate({ c in
            editItem(id, &c) { i in
                if let name { i.name = name }
                if let complete { i.complete = complete }
                if let due { i.due = due }
                if let member { i.memberId = member?.id; i.member = member }
            }
        }) { [api] in
            try await api.updateCheckItem(id, name: name, complete: complete, due: due, memberId: member.map { $0?.id })
        }
    }

    /// Reorder within or between checklists: put `id` before `beforeId` in `checklist` (nil = end).
    func moveItem(_ id: String, to checklist: String, before beforeId: String?) {
        guard var c = card, let cls = c.checklists else { return }
        var moving: CheckItem?
        for ci in cls.indices { if let ii = c.checklists![ci].items.firstIndex(where: { $0.id == id }) { moving = c.checklists![ci].items.remove(at: ii) } }
        guard var item = moving, let ti = c.checklists!.firstIndex(where: { $0.id == checklist }) else { return }
        item.checklistId = checklist
        let items = c.checklists![ti].items
        let at = beforeId.flatMap { b in items.firstIndex { $0.id == b } } ?? items.count
        let afterId = at > 0 ? items[at - 1].id : nil
        c.checklists![ti].items.insert(item, at: at)
        card = c
        mutate { [api] in try await api.moveCheckItem(id, checklist: checklist, afterId: afterId) }
    }

    func deleteItem(_ id: String) {
        mutate({ c in for ci in (c.checklists ?? []).indices { c.checklists![ci].items.removeAll { $0.id == id } } }) { [api] in
            try await api.deleteCheckItem(id)
        }
    }

    // MARK: comments

    func addComment(_ text: String) {
        mutate { [api, cardId] in try await api.addComment(card: cardId, text: text) }
    }

    func editComment(_ id: String, _ text: String) {
        mutate({ c in if let i = c.comments?.firstIndex(where: { $0.id == id }) { c.comments![i].text = text; c.comments![i].editedAt = Date() } }) { [api] in
            try await api.editComment(id, text: text)
        }
    }

    func deleteComment(_ id: String) {
        mutate({ $0.comments?.removeAll { $0.id == id } }) { [api] in try await api.deleteComment(id) }
    }

    // MARK: attachments

    func upload(_ files: [(name: String, mimeType: String, data: Data)]) {
        guard !files.isEmpty else { return }
        let total = files.reduce(0) { $0 + $1.data.count }
        if total > 100 * 1024 * 1024 { app.flash("Uploads must total under 100 MB."); return }
        uploading += 1
        Task {
            defer { uploading -= 1 }
            do {
                for chunk in stride(from: 0, to: files.count, by: 20) {
                    try await api.uploadAttachments(card: cardId, files: Array(files[chunk..<min(chunk + 20, files.count)]))
                }
            } catch {
                account.handle(error)
                app.flash(error.localizedDescription)
            }
            scheduleReload(after: 50)
            boardModel?.scheduleReload()
        }
    }

    func upload(urls: [URL]) {
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
        mutate { [api, cardId] in try await api.addLink(card: cardId, url: url, name: name) }
    }

    func renameAttachment(_ id: String, _ name: String) {
        mutate({ c in if let i = c.attachments?.firstIndex(where: { $0.id == id }) { c.attachments![i].name = name } }) { [api] in
            try await api.renameAttachment(id, name: name)
        }
    }

    func deleteAttachment(_ id: String) {
        mutate({ c in
            c.attachments?.removeAll { $0.id == id }
            if c.coverAttachmentId == id { c.coverAttachmentId = nil }
        }) { [api] in try await api.deleteAttachment(id) }
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
            app.flash(error.localizedDescription)
            return nil
        }
    }
}
