import Foundation

/// Every tRPC procedure the app uses, typed. Mirrors `src/server/api/routers/*` in the hackban repo;
/// when a router changes, this is the file to update.
public struct HackbanAPI: Sendable {
    public let client: TRPCClient

    public init(client: TRPCClient) { self.client = client }

    // MARK: me

    public func profile() async throws -> Profile { try await client.query("me.profile") }

    public func updateProfile(name: String? = nil, username: String?? = nil) async throws {
        var o: [String: JSONValue] = [:]
        if let name { o["name"] = .string(name) }
        if let username { o["username"] = .optional(username) }
        try await client.mutate("me.update", .object(o))
    }

    public func myActivity(cursor: String? = nil) async throws -> Page<Activity> {
        try await client.query("me.activity", ["cursor": .optional(cursor)])
    }

    public func myCards() async throws -> [Card] { try await client.query("me.cards") }
    public func connectedApps() async throws -> [ConnectedApp] { try await client.query("me.apps") }
    public func revokeApp(_ id: String) async throws { try await client.mutate("me.revokeApp", ["id": .string(id)]) }

    /// The user's connected GitHub account. Connecting one happens in the browser (`/me`), since it's an OAuth
    /// flow tied to the web session.
    public func github() async throws -> GitHubStatus { try await client.query("me.github") }
    public func disconnectGithub() async throws { try await client.mutate("me.disconnectGithub") }

    public func uploadAvatar(userId: String, data: Data, name: String, mimeType: String) async throws {
        _ = try await client.upload("api/users/\(userId)/avatar", files: [(name, mimeType, data)])
    }

    public func removeAvatar(userId: String) async throws { try await client.delete("api/users/\(userId)/avatar") }

    // MARK: notifications & search

    public func notifications() async throws -> [HackbanNotification] { try await client.query("notification.list") }
    public func markAllRead() async throws { try await client.mutate("notification.markAllRead") }
    public func markRead(_ id: String) async throws { try await client.mutate("notification.markRead", ["id": .string(id)]) }
    public func search(_ q: String) async throws -> SearchResults { try await client.query("search.query", ["q": .string(q)]) }

    // MARK: workspaces

    public func workspaces() async throws -> [Workspace] { try await client.query("workspace.list") }
    public func workspace(_ id: String) async throws -> WorkspaceDetail { try await client.query("workspace.get", ["id": .string(id)]) }

    public func createWorkspace(name: String) async throws -> Created {
        try await client.mutate("workspace.create", ["name": .string(name)])
    }

    public func updateWorkspace(_ id: String, name: String? = nil, description: String? = nil) async throws {
        var o: [String: JSONValue] = ["id": .string(id)]
        if let name { o["name"] = .string(name) }
        if let description { o["description"] = .string(description) }
        try await client.mutate("workspace.update", .object(o))
    }

    /// Add by user id, or invite by email (people who haven't logged in yet).
    public func addWorkspaceMember(_ id: String, userId: String? = nil, email: String? = nil, role: String = "normal") async throws {
        var o: [String: JSONValue] = ["id": .string(id), "role": .string(role)]
        if let userId { o["userId"] = .string(userId) }
        if let email { o["email"] = .string(email) }
        try await client.mutate("workspace.addMember", .object(o))
    }

    public func removeWorkspaceMember(_ id: String, userId: String) async throws {
        try await client.mutate("workspace.removeMember", ["id": .string(id), "userId": .string(userId)])
    }

    public func deleteWorkspace(_ id: String, confirmName: String) async throws {
        try await client.mutate("workspace.delete", ["id": .string(id), "confirmName": .string(confirmName)])
    }

    public func autoJoins(_ id: String) async throws -> [AutoJoinRule] { try await client.query("workspace.autoJoins", ["id": .string(id)]) }

    public func addAutoJoin(_ id: String, domain: String) async throws {
        try await client.mutate("workspace.addAutoJoin", ["id": .string(id), "domain": .string(domain), "role": "normal"])
    }

    public func removeAutoJoin(_ id: String, ruleId: String) async throws {
        try await client.mutate("workspace.removeAutoJoin", ["id": .string(id), "ruleId": .string(ruleId)])
    }

    public func uploadLogo(workspaceId: String, data: Data, name: String, mimeType: String) async throws {
        _ = try await client.upload("api/workspaces/\(workspaceId)/logo", files: [(name, mimeType, data)])
    }

    public func removeLogo(workspaceId: String) async throws { try await client.delete("api/workspaces/\(workspaceId)/logo") }

    // MARK: boards

    public func board(_ id: String) async throws -> Board { try await client.query("board.get", ["id": .string(id)]) }
    public func recentBoards() async throws -> [BoardSummary] { try await client.query("board.recent") }
    public func closedBoards() async throws -> [BoardSummary] { try await client.query("board.closed") }
    public func guestBoards() async throws -> [BoardSummary] { try await client.query("board.guestBoards") }

    public func createBoard(name: String, workspaceId: String, background: String, visibility: String = "workspace", template: String = "basic") async throws -> Created {
        try await client.mutate("board.create", [
            "name": .string(name), "workspaceId": .string(workspaceId), "background": .string(background),
            "visibility": .string(visibility), "template": .string(template),
        ])
    }

    public struct BoardPatch: Sendable {
        public var name: String?
        public var description: String?
        public var background: String?
        public var bgImage: String??
        public var visibility: String?
        public var closed: Bool?
        public init(name: String? = nil, description: String? = nil, background: String? = nil, bgImage: String?? = nil, visibility: String? = nil, closed: Bool? = nil) {
            self.name = name; self.description = description; self.background = background
            self.bgImage = bgImage; self.visibility = visibility; self.closed = closed
        }
    }

    public func updateBoard(_ id: String, _ p: BoardPatch) async throws {
        var o: [String: JSONValue] = ["id": .string(id)]
        if let v = p.name { o["name"] = .string(v) }
        if let v = p.description { o["description"] = .string(v) }
        if let v = p.background { o["background"] = .string(v) }
        if let v = p.bgImage { o["bgImage"] = .optional(v) }
        if let v = p.visibility { o["visibility"] = .string(v) }
        if let v = p.closed { o["closed"] = .bool(v) }
        try await client.mutate("board.update", .object(o))
    }

    public func moveBoard(_ id: String, workspaceId: String) async throws {
        try await client.mutate("board.move", ["id": .string(id), "workspaceId": .string(workspaceId)])
    }

    public func copyBoard(_ id: String, name: String, workspaceId: String, keepCards: Bool) async throws -> Created {
        try await client.mutate("board.copy", ["id": .string(id), "name": .string(name), "workspaceId": .string(workspaceId), "keepCards": .bool(keepCards)])
    }

    public func deleteBoard(_ id: String) async throws { try await client.mutate("board.delete", ["id": .string(id)]) }

    public func starBoard(_ id: String, _ starred: Bool) async throws {
        try await client.mutate("board.star", ["id": .string(id), "starred": .bool(starred)])
    }

    public func searchUsers(_ q: String) async throws -> [User] { try await client.query("board.searchUsers", ["q": .string(q)]) }

    public func addBoardMember(_ id: String, userId: String? = nil, email: String? = nil, role: String = "normal") async throws {
        var o: [String: JSONValue] = ["id": .string(id), "role": .string(role)]
        if let userId { o["userId"] = .string(userId) }
        if let email { o["email"] = .string(email) }
        try await client.mutate("board.addMember", .object(o))
    }

    public func removeBoardMember(_ id: String, userId: String) async throws {
        try await client.mutate("board.removeMember", ["id": .string(id), "userId": .string(userId)])
    }

    public func setInviteLink(_ id: String, enabled: Bool, role: String? = nil, reset: Bool = false) async throws -> InviteLink {
        var o: [String: JSONValue] = ["id": .string(id), "enabled": .bool(enabled), "reset": .bool(reset)]
        if let role { o["role"] = .string(role) }
        return try await client.mutate("board.setInviteLink", .object(o))
    }

    public func invitePreview(token: String) async throws -> InvitePreview {
        try await client.query("board.invitePreview", ["token": .string(token)])
    }

    public func joinByInvite(token: String) async throws -> String {
        struct R: Decodable { let boardId: String }
        let r: R = try await client.mutate("board.joinByInvite", ["token": .string(token)])
        return r.boardId
    }

    public func boardActivity(_ id: String, cursor: String? = nil) async throws -> Page<Activity> {
        try await client.query("board.activity", ["id": .string(id), "cursor": .optional(cursor)])
    }

    public func archived(_ boardId: String) async throws -> ArchivedItems { try await client.query("board.archived", ["id": .string(boardId)]) }

    public func exportBoard(_ id: String) async throws -> Data { try await client.download("/api/boards/\(id)/export") }

    // MARK: lists

    public func createList(boardId: String, name: String) async throws -> Created {
        try await client.mutate("list.create", ["boardId": .string(boardId), "name": .string(name)])
    }

    public func updateList(_ id: String, name: String? = nil, color: String?? = nil, closed: Bool? = nil) async throws {
        var o: [String: JSONValue] = ["id": .string(id)]
        if let name { o["name"] = .string(name) }
        if let color { o["color"] = .optional(color) }
        if let closed { o["closed"] = .bool(closed) }
        try await client.mutate("list.update", .object(o))
    }

    /// After `afterId` (nil = first), optionally on another board.
    public func moveList(_ id: String, afterId: String?, toBoard: String? = nil) async throws {
        var o: [String: JSONValue] = ["id": .string(id), "afterId": .optional(afterId)]
        if let toBoard { o["boardId"] = .string(toBoard) }
        try await client.mutate("list.move", .object(o))
    }

    public func copyList(_ id: String, name: String) async throws { try await client.mutate("list.copy", ["id": .string(id), "name": .string(name)]) }
    public func moveAllCards(_ id: String, to listId: String) async throws { try await client.mutate("list.moveAllCards", ["id": .string(id), "toListId": .string(listId)]) }
    public func sortCards(_ id: String, ids: [String]) async throws { try await client.mutate("list.sortCards", ["id": .string(id), "ids": .strings(ids)]) }
    public func archiveAllCards(_ id: String) async throws { try await client.mutate("list.archiveAllCards", ["id": .string(id)]) }
    public func deleteList(_ id: String) async throws { try await client.mutate("list.delete", ["id": .string(id)]) }

    // MARK: cards

    public func card(_ id: String) async throws -> Card { try await client.query("card.get", ["id": .string(id)]) }

    /// `position`: nil = bottom, `.some(nil)` = top, `.some(id)` = after that card.
    public func createCard(listId: String, title: String, after position: String?? = nil) async throws -> Card {
        var o: [String: JSONValue] = ["listId": .string(listId), "title": .string(title)]
        if let position { o["afterId"] = .optional(position) }
        return try await client.mutate("card.create", .object(o))
    }

    public struct CardPatch: Sendable, Equatable {
        public var title: String?
        public var description: String?
        public var start: Date??
        public var due: Date??
        public var dueComplete: Bool?
        public var coverColor: String??
        public var coverAttachmentId: String??
        public var coverSize: String?
        public var closed: Bool?
        public var recurrence: String??

        public init(title: String? = nil, description: String? = nil, start: Date?? = nil, due: Date?? = nil, dueComplete: Bool? = nil,
                    coverColor: String?? = nil, coverAttachmentId: String?? = nil, coverSize: String? = nil, closed: Bool? = nil, recurrence: String?? = nil) {
            self.title = title; self.description = description; self.start = start; self.due = due
            self.dueComplete = dueComplete; self.coverColor = coverColor; self.coverAttachmentId = coverAttachmentId
            self.coverSize = coverSize; self.closed = closed; self.recurrence = recurrence
        }

        public var input: [String: JSONValue] {
            var o: [String: JSONValue] = [:]
            if let v = title { o["title"] = .string(v) }
            if let v = description { o["description"] = .string(v) }
            if let v = start { o["start"] = .optional(v) }
            if let v = due { o["due"] = .optional(v) }
            if let v = dueComplete { o["dueComplete"] = .bool(v) }
            if let v = coverColor { o["coverColor"] = .optional(v) }
            if let v = coverAttachmentId { o["coverAttachmentId"] = .optional(v) }
            if let v = coverSize { o["coverSize"] = .string(v) }
            if let v = closed { o["closed"] = .bool(v) }
            if let v = recurrence { o["recurrence"] = .optional(v) }
            return o
        }

        /// What the server will store, applied locally for optimistic updates.
        public func apply(to c: inout Card) {
            if let v = title { c.title = v }
            if let v = description { c.description = v }
            if let v = start { c.start = v }
            if let v = due { c.due = v }
            if let v = dueComplete { c.dueComplete = v }
            if let v = coverColor { c.coverColor = v; if v != nil { c.coverAttachmentId = nil; c.coverUrl = nil } }
            if let v = coverAttachmentId { c.coverAttachmentId = v; if v != nil { c.coverColor = nil } else { c.coverUrl = nil } }
            if let v = coverSize { c.coverSize = v }
            if let v = closed { c.closed = v }
            if let v = recurrence { c.recurrence = v }
        }
    }

    public func updateCard(_ id: String, _ patch: CardPatch) async throws {
        var o = patch.input
        o["id"] = .string(id)
        try await client.mutate("card.update", .object(o))
    }

    /// Into `listId` after `afterId` (nil = top).
    public func moveCard(_ id: String, listId: String, afterId: String?) async throws {
        try await client.mutate("card.move", ["id": .string(id), "listId": .string(listId), "afterId": .optional(afterId)])
    }

    public struct CopyKeep: Sendable {
        public var checklists = true, labels = true, members = true, attachments = true
        public init() {}
    }

    public func copyCard(_ id: String, title: String, listId: String, afterId: String?? = nil, keep: CopyKeep = .init()) async throws -> Created {
        var o: [String: JSONValue] = [
            "id": .string(id), "title": .string(title), "listId": .string(listId),
            "keep": ["checklists": .bool(keep.checklists), "labels": .bool(keep.labels), "members": .bool(keep.members), "attachments": .bool(keep.attachments)],
        ]
        if let afterId { o["afterId"] = .optional(afterId) }
        return try await client.mutate("card.copy", .object(o))
    }

    public func deleteCard(_ id: String) async throws { try await client.mutate("card.delete", ["id": .string(id)]) }

    public func toggleLabel(card: String, label: String, on: Bool) async throws {
        try await client.mutate("card.toggleLabel", ["id": .string(card), "labelId": .string(label), "on": .bool(on)])
    }

    public func toggleMember(card: String, user: String, on: Bool) async throws {
        try await client.mutate("card.toggleMember", ["id": .string(card), "userId": .string(user), "on": .bool(on)])
    }

    public func watchCard(_ id: String, _ on: Bool) async throws { try await client.mutate("card.watch", ["id": .string(id), "on": .bool(on)]) }

    public func setBlocker(card: String, blocker: String, on: Bool) async throws {
        try await client.mutate("card.setBlocker", ["id": .string(card), "blockerId": .string(blocker), "on": .bool(on)])
    }

    // Labels (board-scoped)
    public func createLabel(boardId: String, name: String, color: String?) async throws -> Label {
        try await client.mutate("card.createLabel", ["boardId": .string(boardId), "name": .string(name), "color": .optional(color)])
    }

    public func updateLabel(_ id: String, name: String, color: String?) async throws {
        try await client.mutate("card.updateLabel", ["id": .string(id), "name": .string(name), "color": .optional(color)])
    }

    public func deleteLabel(_ id: String) async throws { try await client.mutate("card.deleteLabel", ["id": .string(id)]) }

    // Checklists
    @discardableResult
    public func addChecklist(card: String, name: String, copyFrom: String? = nil) async throws -> Created {
        var o: [String: JSONValue] = ["id": .string(card), "name": .string(name)]
        if let copyFrom { o["copyFrom"] = .string(copyFrom) }
        return try await client.mutate("card.addChecklist", .object(o))
    }

    public func renameChecklist(_ id: String, name: String) async throws {
        try await client.mutate("card.updateChecklist", ["checklistId": .string(id), "name": .string(name)])
    }

    public func deleteChecklist(_ id: String) async throws { try await client.mutate("card.deleteChecklist", ["checklistId": .string(id)]) }

    public func addCheckItem(checklist: String, name: String) async throws {
        try await client.mutate("card.addCheckItem", ["checklistId": .string(checklist), "name": .string(name)])
    }

    public func updateCheckItem(_ id: String, name: String? = nil, complete: Bool? = nil, due: Date?? = nil, memberId: String?? = nil) async throws {
        var o: [String: JSONValue] = ["itemId": .string(id)]
        if let name { o["name"] = .string(name) }
        if let complete { o["complete"] = .bool(complete) }
        if let due { o["due"] = .optional(due) }
        if let memberId { o["memberId"] = .optional(memberId) }
        try await client.mutate("card.updateCheckItem", .object(o))
    }

    public func moveCheckItem(_ id: String, checklist: String, afterId: String?) async throws {
        try await client.mutate("card.moveCheckItem", ["itemId": .string(id), "checklistId": .string(checklist), "afterId": .optional(afterId)])
    }

    public func deleteCheckItem(_ id: String) async throws { try await client.mutate("card.deleteCheckItem", ["itemId": .string(id)]) }

    // Comments
    @discardableResult
    public func addComment(card: String, text: String) async throws -> Created {
        try await client.mutate("card.addComment", ["id": .string(card), "text": .string(text)])
    }
    public func editComment(_ id: String, text: String) async throws { try await client.mutate("card.editComment", ["commentId": .string(id), "text": .string(text)]) }
    public func deleteComment(_ id: String) async throws { try await client.mutate("card.deleteComment", ["commentId": .string(id)]) }

    // Attachments
    public func addLink(card: String, url: String, name: String? = nil) async throws {
        var o: [String: JSONValue] = ["id": .string(card), "url": .string(url)]
        if let name, !name.isEmpty { o["name"] = .string(name) }
        try await client.mutate("card.addLink", .object(o))
    }

    public func renameAttachment(_ id: String, name: String) async throws {
        try await client.mutate("card.updateAttachment", ["attachmentId": .string(id), "name": .string(name)])
    }

    public func deleteAttachment(_ id: String) async throws { try await client.mutate("card.deleteAttachment", ["attachmentId": .string(id)]) }

    /// Upload files to a card (up to 20 at a time, 100 MB total).
    public func uploadAttachments(card: String, files: [(name: String, mimeType: String, data: Data)]) async throws {
        _ = try await client.upload("api/cards/\(card)/attachments", files: files)
    }

    // GitHub issues: the card is marked complete when every tracked issue is closed.
    public func trackIssue(card: String, url: String) async throws {
        try await client.mutate("card.trackIssue", ["id": .string(card), "url": .string(url)])
    }

    public func untrackIssue(_ issueId: String) async throws { try await client.mutate("card.untrackIssue", ["issueId": .string(issueId)]) }

    /// Re-check an issue on GitHub now instead of waiting for the next poll.
    public func refreshIssue(_ issueId: String) async throws { try await client.mutate("card.refreshIssue", ["issueId": .string(issueId)]) }
}
