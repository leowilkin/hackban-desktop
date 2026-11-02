import Foundation

/// Board filters, as in the web app's filter popover.
public struct CardFilters: Equatable, Sendable {
    public enum Due: String, CaseIterable, Sendable {
        case none, overdue, day, week, complete

        public var title: String {
            switch self {
            case .none: return "No dates"
            case .overdue: return "Overdue"
            case .day: return "Due in the next day"
            case .week: return "Due in the next week"
            case .complete: return "Marked as complete"
            }
        }
    }

    public var query = ""
    /// User ids; "none" = cards with no members.
    public var members: Set<String> = []
    /// Label ids; "none" = cards with no labels.
    public var labels: Set<String> = []
    public var due: Set<Due> = []

    public init() {}

    public var isActive: Bool { !query.isEmpty || !members.isEmpty || !labels.isEmpty || !due.isEmpty }

    public func matches(_ c: Card, now: Date = Date()) -> Bool {
        if !query.isEmpty, !c.title.localizedCaseInsensitiveContains(query) { return false }
        if !members.isEmpty {
            let ids = c.memberIds
            if !members.contains(where: { $0 == "none" ? ids.isEmpty : ids.contains($0) }) { return false }
        }
        if !labels.isEmpty {
            let ids = c.labelIds
            if !labels.contains(where: { $0 == "none" ? ids.isEmpty : ids.contains($0) }) { return false }
        }
        if !due.isEmpty {
            let ok = due.contains { d in
                switch d {
                case .none: return c.due == nil
                case .complete: return c.due != nil && c.dueComplete
                default:
                    guard let t = c.due, !c.dueComplete else { return false }
                    switch d {
                    case .overdue: return t < now
                    case .day: return t >= now && t < now.addingTimeInterval(86_400)
                    default: return t >= now && t < now.addingTimeInterval(7 * 86_400)
                    }
                }
            }
            if !ok { return false }
        }
        return true
    }
}

/// List sorts, as in the web app's sort button.
public enum CardSort: String, CaseIterable, Identifiable, Sendable {
    case dueSoonest, nameAZ, nameZA, newest, oldest, mostMembers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dueSoonest: return "Due date (soonest first)"
        case .nameAZ: return "Name (A–Z)"
        case .nameZA: return "Name (Z–A)"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .mostMembers: return "Most members first"
        }
    }

    public func sorted(_ cards: [Card]) -> [Card] {
        func byTitle(_ a: Card, _ b: Card) -> Bool {
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let far = Date.distantFuture, past = Date.distantPast
        switch self {
        case .dueSoonest:
            return cards.sorted { a, b in
                let x = a.due ?? far, y = b.due ?? far
                return x != y ? x < y : byTitle(a, b)
            }
        case .nameAZ: return cards.sorted(by: byTitle)
        case .nameZA: return cards.sorted { byTitle($1, $0) }
        case .newest: return cards.sorted { ($0.createdAt ?? past) > ($1.createdAt ?? past) }
        case .oldest: return cards.sorted { ($0.createdAt ?? past) < ($1.createdAt ?? past) }
        case .mostMembers: return cards.sorted { $0.memberIds.count > $1.memberIds.count }
        }
    }
}

public enum Recurrence: String, CaseIterable, Identifiable, Sendable {
    case daily, weekdays, weekly, monthly, yearly

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays: return "Every weekday"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

public enum DueStatus: Sendable {
    case complete, overdue, soon, later

    public static func of(_ c: Card, now: Date = Date()) -> DueStatus? {
        guard let due = c.due else { return nil }
        if c.dueComplete { return .complete }
        if due < now { return .overdue }
        if due < now.addingTimeInterval(86_400) { return .soon }
        return .later
    }
}

/// Text for an activity entry, matching the web app's wording. `onCard` = shown inside that card.
public enum ActivityText {
    public static func describe(_ a: Activity, onCard: Bool = false) -> String {
        let card = (a.card != nil && !onCard) ? a.card!.title : "this card"
        let d = a.data
        func s(_ k: String) -> String { d[k]?.string ?? "" }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MMM d 'at' h:mm a"
        let shortFmt = DateFormatter()
        shortFmt.dateFormat = "MMM d"
        switch a.type {
        case "createBoard": return "created this board"
        case "importBoard": return "imported this board from Trello"
        case "renameBoard": return "renamed this board to \(s("name"))"
        case "closeBoard": return "closed this board"
        case "reopenBoard": return "reopened this board"
        case "moveBoard": return "moved this board from \(s("from")) to \(s("to"))"
        case "createList": return "added list \(s("name")) to this board"
        case "renameList": return "renamed list to \(s("name"))"
        case "archiveList": return "archived list \(s("name"))"
        case "restoreList": return "sent list \(s("name")) to the board"
        case "moveList": return "moved list \(s("name"))"
        case "moveListFromBoard": return "moved list \(s("name")) to another board"
        case "deleteList": return "deleted a list"
        case "createCard": return "added \(card) to this board"
        case "renameCard": return "renamed \(card)"
        case "updateDescription": return "updated the description of \(card)"
        case "archiveCard": return "archived \(card)"
        case "restoreCard": return "sent \(card) to the board"
        case "deleteCard": return "deleted card \(s("title"))"
        case "moveCard": return "moved \(card) from \(s("from")) to \(s("to"))"
        case "copyCard": return "copied \(card) from \(s("from"))"
        case "changeDue":
            if let due = d["due"]?.dateValue { return "set \(card) to be due \(dateFmt.string(from: due))" }
            return "removed the due date from \(card)"
        case "recurCard":
            let next = d["due"]?.dateValue.map { shortFmt.string(from: $0) } ?? "soon"
            return "completed \(card); it repeats, next due \(next)"
        case "changeRecurrence":
            let r = s("recurrence")
            if r.isEmpty { return "stopped \(card) repeating" }
            return "set \(card) to repeat \(r == "weekdays" ? "every weekday" : r)"
        case "completeDue": return "marked the due date on \(card) complete"
        case "incompleteDue": return "marked the due date on \(card) incomplete"
        case "addMemberToCard": return "joined \(card)"
        case "removeMemberFromCard": return "left \(card)"
        case "addChecklist": return "added \(s("name")) to \(card)"
        case "removeChecklist": return "removed \(s("name")) from \(card)"
        case "completeCheckItem": return "completed \(s("name")) on \(card)"
        case "incompleteCheckItem": return "marked \(s("name")) incomplete on \(card)"
        case "addBlocker": return "marked \(card) as blocked by \(s("name"))"
        case "removeBlocker": return "marked \(card) as no longer blocked by \(s("name"))"
        case "addAttachment": return "attached \(s("name")) to \(card)"
        case "trackIssue": return "linked GitHub issue \(s("issue")) to \(card)"
        case "untrackIssue": return "unlinked GitHub issue \(s("issue")) from \(card)"
        case "githubIssueClosed":
            let by = s("closedBy")
            return "completed \(card) because GitHub issue \(s("issue")) was closed" + (by.isEmpty ? "" : " by @\(by)")
        case "githubIssueReopened": return "reopened \(card) because GitHub issue \(s("issue")) was reopened"
        case "addMemberToBoard": return "added a member to this board"
        case "joinBoard": return "joined this board via invite link"
        case "archiveAllCards": return "archived all cards in a list"
        case "sortList": return "sorted a list"
        case "moveAllCards": return "moved \(s("count")) cards"
        default: return a.type
        }
    }
}

/// Hackban's colour palette (from the web app's ui.tsx), as hex strings.
public enum Palette {
    /// name → (subtle, mid, bold) for light mode
    public static let light: [String: (String, String, String)] = [
        "green": ("#baf3db", "#4bce97", "#1f845a"),
        "yellow": ("#f8e6a0", "#f5cd47", "#946f00"),
        "orange": ("#fedec8", "#fea362", "#c25100"),
        "red": ("#ffd5d2", "#f87168", "#c9372c"),
        "purple": ("#dfd8fd", "#9f8fef", "#6e5dc6"),
        "blue": ("#cce0ff", "#579dff", "#0c66e4"),
        "sky": ("#c6edfb", "#6cc3e0", "#227d9b"),
        "lime": ("#d3f1a7", "#94c748", "#5b7f24"),
        "pink": ("#fdd0ec", "#e774bb", "#ae4787"),
        "black": ("#dcdfe4", "#8590a2", "#626f86"),
    ]
    public static let dark: [String: (String, String, String)] = [
        "green": ("#164b35", "#216e4e", "#4bce97"),
        "yellow": ("#533f04", "#7f5f01", "#e2b203"),
        "orange": ("#702e00", "#a54800", "#fea362"),
        "red": ("#5d1f1a", "#ae2e24", "#f87168"),
        "purple": ("#352c63", "#5e4db2", "#9f8fef"),
        "blue": ("#09326c", "#0055cc", "#579dff"),
        "sky": ("#164555", "#206a83", "#6cc3e0"),
        "lime": ("#37471f", "#4c6b1f", "#94c748"),
        "pink": ("#50253f", "#943d73", "#e774bb"),
        "black": ("#454f59", "#596773", "#8c9bab"),
    ]
    public static let baseNames = ["green", "yellow", "orange", "red", "purple", "blue", "sky", "lime", "pink", "black"]
    /// Every label colour: "green_light", "green", "green_dark", …
    public static let labelColors = baseNames.flatMap { ["\($0)_light", $0, "\($0)_dark"] }

    public struct LabelStyle: Equatable, Sendable {
        public let background: String
        public let foreground: String
    }

    public static func label(_ color: String?, dark isDark: Bool) -> LabelStyle? {
        guard let color else { return nil }
        let parts = color.split(separator: "_").map(String.init)
        let base = parts.first ?? "black"
        let variant = parts.count > 1 ? parts[1] : nil
        let set = (isDark ? dark : light)[base] ?? (isDark ? dark : light)["black"]!
        switch variant {
        case "light": return LabelStyle(background: set.0, foreground: isDark ? "#dee4ea" : "#172b4d")
        case "dark": return LabelStyle(background: set.2, foreground: isDark ? "#1d2125" : "#ffffff")
        default: return LabelStyle(background: set.1, foreground: isDark ? "#ffffff" : "#172b4d")
        }
    }

    /// Cover colours and list colours use the mid shade of a base name.
    public static func mid(_ name: String?) -> String? {
        guard let name, let set = light[name] else { return nil }
        return set.1
    }

    public static let boardColors = ["#0079bf", "#d29034", "#519839", "#b04632", "#89609e", "#cd5a91", "#4bbf6b", "#00aecc", "#838c91"]
    public static let boardGradients = [
        "linear-gradient(135deg, #0c66e4 0%, #37b4c3 100%)",
        "linear-gradient(135deg, #09326c 0%, #0c66e4 100%)",
        "linear-gradient(135deg, #5e4db2 0%, #e774bb 100%)",
        "linear-gradient(135deg, #e34935 0%, #faa53d 100%)",
        "linear-gradient(135deg, #1f845a 0%, #7ee2b8 100%)",
        "linear-gradient(135deg, #172b4d 0%, #44546f 100%)",
    ]

    /// Hex stops of a board background: one for a colour, several for a `linear-gradient(…)`.
    public static func backgroundStops(_ css: String?) -> [String] {
        guard let css else { return ["#0079bf"] }
        var out: [String] = []
        var i = css.startIndex
        while let r = css.range(of: "#", range: i..<css.endIndex) {
            var j = r.upperBound
            while j < css.endIndex, css[j].isHexDigit { j = css.index(after: j) }
            out.append(String(css[r.lowerBound..<j]))
            i = j
        }
        return out.isEmpty ? ["#0079bf"] : out
    }
}

/// "#rgb", "#rrggbb" or "#rrggbbaa" → components in 0…1.
public func parseHex(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
    guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
    if s.count == 6 {
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255, 1)
    }
    return (Double((v >> 24) & 0xff) / 255, Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
}
