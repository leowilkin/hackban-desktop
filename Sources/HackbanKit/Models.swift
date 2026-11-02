import Foundation

// Shapes of Hackban's tRPC outputs. Prisma rows come back whole, with relations the procedure
// includes. Fields that only some procedures return are optional, so one type serves every
// procedure that returns that kind of row and decoding survives the server adding fields.

public struct User: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String?
    public var image: String?
    public var username: String?
    public var email: String?
    public var isGhost: Bool?
    public var invitedEmail: String?

    public init(id: String, name: String? = nil, image: String? = nil, username: String? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.username = username
    }

    public var displayName: String { name ?? username ?? email ?? "Unknown" }

    public var initials: String {
        guard let name, !name.isEmpty else { return "?" }
        return name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}

public struct Profile: Codable, Hashable, Sendable {
    public let id: String
    public var name: String?
    public var email: String?
    public var image: String?
    public var avatarKey: String?
    public var username: String?
    public var trelloId: String?
    public var isAdmin: Bool?
    public var createdAt: Date?

    public var asUser: User { User(id: id, name: name, image: image, username: username) }
}

public struct WorkspaceRef: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
}

public struct BoardRef: Codable, Hashable, Sendable {
    /// Missing on `card.get`'s `list.board`.
    public var id: String?
    public var name: String
    public var background: String?
    public var bgImage: String?
    public init(id: String?, name: String, background: String? = nil, bgImage: String? = nil) {
        self.id = id
        self.name = name
        self.background = background
        self.bgImage = bgImage
    }
}

public struct Label: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var boardId: String?
    public var name: String
    public var color: String?

    public init(id: String, boardId: String? = nil, name: String, color: String?) {
        self.id = id
        self.boardId = boardId
        self.name = name
        self.color = color
    }
}

public struct CardLabel: Codable, Hashable, Sendable {
    public var cardId: String?
    public let labelId: String
    public var label: Label

    public init(cardId: String?, labelId: String, label: Label) {
        self.cardId = cardId
        self.labelId = labelId
        self.label = label
    }
}

public struct CardMember: Codable, Hashable, Sendable {
    public var cardId: String?
    public let userId: String
    public var user: User

    public init(cardId: String?, userId: String, user: User) {
        self.cardId = cardId
        self.userId = userId
        self.user = user
    }
}

public struct CardCounts: Codable, Hashable, Sendable {
    public var comments: Int
    public var attachments: Int
}

/// `{ blocker: { title } }` / `{ blocked: { title } }` on card fronts.
public struct DepTitle: Codable, Hashable, Sendable {
    public struct T: Codable, Hashable, Sendable { public var title: String }
    public var blocker: T?
    public var blocked: T?
}

/// A dependency on the card detail: `{ id, title, dueComplete }`.
public struct Dependency: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var dueComplete: Bool
}

/// `owner/repo#number`, the parts of a GitHub issue link.
public struct GitHubIssueRef: Codable, Hashable, Sendable {
    public var owner: String
    public var repo: String
    public var number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    /// `https://github.com/owner/repo/issues/123` (optional www, trailing slash, query or fragment); anything
    /// else, including pull requests, is nil. Same rule as the server's `parseIssueUrl`.
    public static func parse(_ url: String) -> GitHubIssueRef? {
        let pattern = #"^https?://(?:www\.)?github\.com/([\w.-]+)/([\w.-]+)/issues/(\d+)/?(?:[?#].*)?$"#
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let o = Range(m.range(at: 1), in: text), let r = Range(m.range(at: 2), in: text), let n = Range(m.range(at: 3), in: text),
              let number = Int(text[n]), number >= 1
        else { return nil }
        return GitHubIssueRef(owner: String(text[o]), repo: String(text[r]), number: number)
    }

    public var label: String { "\(owner)/\(repo)#\(number)" }
    public var url: URL { URL(string: "https://github.com/\(owner)/\(repo)/issues/\(number)")! }
}

/// A GitHub issue a card tracks. Card fronts carry the first few fields; `card.get` the lot.
public struct GitHubIssue: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var cardId: String?
    public var owner: String
    public var repo: String
    public var number: Int
    public var title: String?
    /// open | closed
    public var state: String
    /// completed | not_planned | reopened | duplicate
    public var stateReason: String?
    /// GitHub login.
    public var closedBy: String?
    public var closedAt: Date?
    public var checkedAt: Date?
    /// Why the last fetch failed (`not_found`: missing, private, or a pull request); nil when it worked.
    public var fetchError: String?
    public var completedCardAt: Date?
    public var addedById: String?
    public var createdAt: Date?

    public init(id: String, cardId: String? = nil, ref: GitHubIssueRef, title: String? = nil, state: String = "open") {
        self.id = id
        self.cardId = cardId
        owner = ref.owner
        repo = ref.repo
        number = ref.number
        self.title = title
        self.state = state
    }

    public var ref: GitHubIssueRef { GitHubIssueRef(owner: owner, repo: repo, number: number) }
    public var label: String { ref.label }
    public var url: URL { ref.url }
    public var isClosed: Bool { state == "closed" }
    public var isUnreadable: Bool { fetchError != nil }
    /// The issue's title, or `owner/repo#N` until it's been fetched.
    public var displayTitle: String { title?.isEmpty == false ? title! : label }
}

/// `me.github`: whether this server can connect GitHub accounts, and the user's if they have.
public struct GitHubStatus: Decodable, Hashable, Sendable {
    public struct Connection: Decodable, Hashable, Sendable {
        public var login: String
        public var createdAt: Date?
    }
    public var available: Bool
    public var connection: Connection?
}

public struct ListRef: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var boardId: String?
    public var board: BoardRef?
    public init(id: String?, name: String, boardId: String?, board: BoardRef?) {
        self.id = id
        self.name = name
        self.boardId = boardId
        self.board = board
    }
}

public struct CheckItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var checklistId: String
    public var name: String
    public var pos: String
    public var complete: Bool
    public var due: Date?
    public var memberId: String?
    public var member: User?
}

public struct Checklist: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var cardId: String
    public var name: String
    public var pos: String
    public var items: [CheckItem]

    public var done: Int { items.filter(\.complete).count }
}

public struct Attachment: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var cardId: String?
    public var uploaderId: String?
    public var name: String?
    public var url: String
    public var mimeType: String?
    public var size: Int?
    public var isUpload: Bool?
    public var createdAt: Date?
    public var uploader: User?

    public var isImage: Bool { mimeType?.hasPrefix("image/") == true }
    public var displayName: String { name ?? url }
}

public struct Comment: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var cardId: String
    public var authorId: String
    public var text: String
    public var createdAt: Date
    public var editedAt: Date?
    public var author: User?
}

public struct Activity: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var boardId: String
    public var cardId: String?
    public var actorId: String
    public var type: String
    public var data: JSONValue
    public var createdAt: Date
    public var actor: User?
    public var card: CardTitle?
    public var board: BoardRef?

    public struct CardTitle: Codable, Hashable, Sendable {
        public let id: String
        public var title: String
    }
}

public struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    public var items: [T]
    public var next: String?
}

/// A card: card fronts on a board, the full card (`card.get`), search hits, "my cards", archived cards.
public struct Card: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var listId: String
    public var title: String
    public var description: String
    public var pos: String
    public var start: Date?
    public var due: Date?
    public var dueComplete: Bool
    public var recurrence: String?
    public var coverColor: String?
    public var coverAttachmentId: String?
    public var coverSize: String?
    public var closed: Bool
    public var shortId: Int?
    public var createdAt: Date?
    public var updatedAt: Date?

    public var labels: [CardLabel]?
    public var members: [CardMember]?
    public var watching: Bool?
    /// GitHub issues it tracks (fronts and detail). Nil on servers without issue tracking.
    public var issues: [GitHubIssue]?

    // Board card fronts
    public var _count: CardCounts?
    public var checkTotal: Int?
    public var checkDone: Int?
    public var coverUrl: String?
    /// Fronts: titles of unfinished blockers/blocked. Detail: see `blockers`/`blocks`.
    private var blockedBy: [DepEither]?
    private var blocking: [DepEither]?

    // card.get
    public var list: ListRef?
    public var checklists: [Checklist]?
    public var attachments: [Attachment]?
    public var comments: [Comment]?
    public var activities: [Activity]?

    /// Card fronts return `{blocker: {title}}`, card.get returns `{id, title, dueComplete}`.
    enum DepEither: Codable, Hashable, Sendable {
        case title(String)
        case dep(Dependency)

        init(from decoder: Decoder) throws {
            if let d = try? Dependency(from: decoder) { self = .dep(d); return }
            let t = try DepTitle(from: decoder)
            self = .title(t.blocker?.title ?? t.blocked?.title ?? "")
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .dep(let d): try d.encode(to: encoder)
            case .title(let t): try DepTitle(blocker: .init(title: t), blocked: nil).encode(to: encoder)
            }
        }
    }

    /// Unfinished cards blocking this one (card fronts: titles; card detail: open blockers).
    public var blockedByTitles: [String] {
        (blockedBy ?? []).compactMap {
            switch $0 {
            case .title(let t): return t
            case .dep(let d): return d.dueComplete ? nil : d.title
            }
        }
    }

    public var blockingTitles: [String] {
        (blocking ?? []).compactMap {
            switch $0 {
            case .title(let t): return t
            case .dep(let d): return d.dueComplete ? nil : d.title
            }
        }
    }

    /// card.get only: blockers with ids.
    public var blockers: [Dependency] {
        get { (blockedBy ?? []).compactMap { if case .dep(let d) = $0 { return d } else { return nil } } }
        set { blockedBy = newValue.map { .dep($0) } }
    }

    public var blocks: [Dependency] {
        get { (blocking ?? []).compactMap { if case .dep(let d) = $0 { return d } else { return nil } } }
        set { blocking = newValue.map { .dep($0) } }
    }

    public var labelIds: [String] { (labels ?? []).map(\.labelId) }
    public var trackedIssues: [GitHubIssue] { issues ?? [] }
    /// Whether this server tracks GitHub issues (the field is only there when it does).
    public var tracksIssues: Bool { issues != nil }
    public var memberIds: [String] { (members ?? []).map(\.userId) }
    public var isBlocked: Bool { !blockedByTitles.isEmpty }
    public var isBlocking: Bool { !blockingTitles.isEmpty }

    public var commentCount: Int { _count?.comments ?? comments?.count ?? 0 }
    public var attachmentCount: Int { _count?.attachments ?? attachments?.count ?? 0 }

    public var checkCounts: (done: Int, total: Int) {
        if let checkTotal { return (checkDone ?? 0, checkTotal) }
        let items = (checklists ?? []).flatMap(\.items)
        return (items.filter(\.complete).count, items.count)
    }
}

extension Card {
    /// A card made on this device that the server hasn't seen yet.
    init(localId id: String, listId: String, title: String) {
        self.id = id
        self.listId = listId
        self.title = title
        description = ""
        pos = ""
        dueComplete = false
        closed = false
        labels = []
        members = []
        watching = false
    }
}

public struct BoardMember: Codable, Hashable, Sendable {
    public var boardId: String?
    public let userId: String
    /// admin | normal | observer
    public var role: String
    public var lastViewed: Date?
    public var user: User
    /// On the board but not in its workspace.
    public var guest: Bool?
}

public struct BoardList: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var boardId: String
    public var name: String
    public var pos: String
    public var color: String?
    public var closed: Bool
    public var cards: [Card]?

    public var openCards: [Card] { cards ?? [] }
}

/// `board.get`.
public struct Board: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var description: String?
    public var workspaceId: String
    public var background: String
    public var bgImage: String?
    /// private | workspace | public
    public var visibility: String
    public var closed: Bool
    public var inviteRole: String?
    public var inviteToken: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var workspace: WorkspaceRef?
    public var members: [BoardMember]
    public var labels: [Label]
    public var lists: [BoardList]
    public var starred: Bool
    /// admin | normal | observer
    public var myRole: String

    public var canEdit: Bool { myRole != "observer" }
    public var isAdmin: Bool { myRole == "admin" }

    public func member(_ userId: String) -> BoardMember? { members.first { $0.userId == userId } }
    public func label(_ id: String) -> Label? { labels.first { $0.id == id } }

    public func list(containing cardId: String) -> (index: Int, cardIndex: Int)? {
        for (li, l) in lists.enumerated() {
            if let ci = l.openCards.firstIndex(where: { $0.id == cardId }) { return (li, ci) }
        }
        return nil
    }
}

/// Board rows in workspace lists, recents, guest boards, search, closed boards.
public struct BoardSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var description: String?
    public var workspaceId: String?
    public var background: String?
    public var bgImage: String?
    public var visibility: String?
    public var closed: Bool?
    public var starred: Bool?
    public var updatedAt: Date?
    public var lastActive: Date?
    public var workspace: WorkspaceRef?
    public var _count: MemberCount?

    public struct MemberCount: Codable, Hashable, Sendable { public var members: Int }
}

/// `workspace.list`.
public struct Workspace: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var description: String?
    public var logo: String?
    public var createdAt: Date?
    public var boards: [BoardSummary]
}

public struct WorkspaceMember: Codable, Hashable, Sendable {
    public var workspaceId: String?
    public let userId: String
    /// admin | normal
    public var role: String
    public var user: User
}

/// `workspace.get`.
public struct WorkspaceDetail: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var description: String?
    public var logo: String?
    public var members: [WorkspaceMember]
    public var boards: [BoardSummary]
    public var myRole: String

    public var isAdmin: Bool { myRole == "admin" }
}

public struct AutoJoinRule: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var workspaceId: String
    public var domain: String
    public var role: String
    public var createdAt: Date?
    public var createdBy: Creator?
    public var memberCount: Int?

    public struct Creator: Codable, Hashable, Sendable { public var name: String? }
}

public struct HackbanNotification: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var type: String
    public var data: [String: String]
    public var read: Bool
    public var createdAt: Date

    public var cardId: String? { data["cardId"] }
    public var boardId: String? { data["boardId"] }

    public var summary: String {
        let by = data["by"] ?? "Someone"
        let title = data["title"] ?? "a card"
        switch type {
        case "addedToCard": return "\(by) added you to the card \(title)"
        case "commentCard": return "\(by) commented on the card \(title)"
        default: return "\(by): \(title)"
        }
    }
}

public struct SearchResults: Decodable, Sendable {
    public var boards: [BoardSummary]
    public var cards: [Card]
}

public struct ArchivedItems: Decodable, Sendable {
    public var cards: [Card]
    public var lists: [BoardList]
}

public struct InviteLink: Decodable, Sendable {
    public var inviteToken: String?
    public var inviteRole: String
}

public struct InvitePreview: Decodable, Sendable {
    public let id: String
    public var name: String
    public var background: String?
    public var bgImage: String?
    public var closed: Bool?
    public var inviteRole: String
    public var workspace: WorkspaceRef?
    public var alreadyMember: Bool
    public var _count: BoardSummary.MemberCount?
}

public struct ConnectedApp: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var lastActive: Date?
}

/// Rows returned by create/update mutations that the app needs an id from.
public struct Created: Decodable, Sendable {
    public let id: String
}
