import Foundation

/// Todoist-style quick-add syntax:
///
///     Write launch post #Marketing /Doing @me @sam !urgent tomorrow 5pm
///
/// - `#board` (or `#board/list`, or `#"Board name"`) picks the board; spaces and punctuation in names
///   can be left out, and a unique prefix is enough.
/// - `/list` picks a list on that board.
/// - `@me` / `@name` assigns members of that board.
/// - `!label` adds a label (by name, or by colour for unnamed labels).
/// - Dates: `today`, `tonight`, `tomorrow`, weekdays (`fri`, `next monday`), `next week`, `next month`,
///   `weekend`, `in 3 days`, `in 2 weeks`, `in 4 hours`, `jan 5`, `5 jan 2027`, `2026-12-01`, with an
///   optional time (`5pm`, `5:30pm`, `17:00`, `noon`), optionally led by `on`, `by`, `due` or `at`.
///
/// Only tokens that match something real are taken out of the title; anything else stays as typed.
public enum QuickAddParser {
    public struct Board: Sendable, Hashable {
        /// Caller's key (e.g. "account|boardId"); returned in the result.
        public let key: String
        public let name: String
        public let lists: [Named]
        public let labels: [Label]
        public let members: [User]
        /// The current user's id on this board's server, for `@me`.
        public let meId: String?

        public init(key: String, name: String, lists: [Named], labels: [Label] = [], members: [User] = [], meId: String? = nil) {
            self.key = key; self.name = name; self.lists = lists; self.labels = labels; self.members = members; self.meId = meId
        }
    }

    public struct Named: Sendable, Hashable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public struct Token: Sendable, Hashable {
        public enum Kind: String, Sendable { case board, list, member, label, due }
        public let kind: Kind
        /// What was typed.
        public let text: String
        /// What it resolved to (board name, list name, member name, label name, formatted date).
        public let display: String
    }

    public struct Result: Sendable, Equatable {
        public var title: String
        public var boardKey: String?
        public var listId: String?
        public var memberIds: [String] = []
        public var labelIds: [String] = []
        public var due: Date?
        public var tokens: [Token] = []

        public init(title: String, boardKey: String? = nil, listId: String? = nil) {
            self.title = title
            self.boardKey = boardKey
            self.listId = listId
        }
    }

    /// - Parameters:
    ///   - defaultBoard: board to resolve `/list`, `@member` and `!label` against when there's no `#board`.
    ///   - defaultHour: time for dates given without one.
    public static func parse(
        _ text: String,
        boards: [Board],
        defaultBoard: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        defaultHour: Int = 12
    ) -> Result {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result = Result(title: "")
        var consumed = Set<Int>()

        // #board, #board/list, #"Board name"
        joinQuoted(&words)
        var board: Board? = defaultBoard.flatMap { k in boards.first { $0.key == k } }
        for (i, w) in words.enumerated() where w.hasPrefix("#") && w.count > 1 {
            var name = String(w.dropFirst())
            var listName: String?
            if !name.hasPrefix("\""), let slash = name.firstIndex(of: "/") {
                listName = String(name[name.index(after: slash)...])
                name = String(name[..<slash])
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let b = best(name, in: boards, by: \.name) else { continue }
            board = b
            result.boardKey = b.key
            consumed.insert(i)
            result.tokens.append(Token(kind: .board, text: w, display: b.name))
            if let listName, let l = best(listName, in: b.lists, by: \.name) {
                result.listId = l.id
                result.tokens.append(Token(kind: .list, text: "/" + listName, display: l.name))
            }
            break
        }

        if let b = board {
            for (i, w) in words.enumerated() where !consumed.contains(i) && w.count > 1 {
                let body = String(w.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "\",.;"))
                switch w.first {
                case "/" where result.listId == nil:
                    if let l = best(body, in: b.lists, by: \.name) {
                        result.listId = l.id
                        consumed.insert(i)
                        result.tokens.append(Token(kind: .list, text: w, display: l.name))
                    }
                case "@":
                    if body.lowercased() == "me", let me = b.meId {
                        if !result.memberIds.contains(me) { result.memberIds.append(me) }
                        consumed.insert(i)
                        result.tokens.append(Token(kind: .member, text: w, display: "Me"))
                    } else if let u = member(body, in: b.members) {
                        if !result.memberIds.contains(u.id) { result.memberIds.append(u.id) }
                        consumed.insert(i)
                        result.tokens.append(Token(kind: .member, text: w, display: u.displayName))
                    }
                case "!":
                    if let l = label(body, in: b.labels) {
                        if !result.labelIds.contains(l.id) { result.labelIds.append(l.id) }
                        consumed.insert(i)
                        result.tokens.append(Token(kind: .label, text: w, display: l.name.isEmpty ? (l.color ?? "label") : l.name))
                    }
                default: break
                }
            }
        }

        // Dates: longest phrase wins, scanning left to right over what's left.
        var i = 0
        while i < words.count {
            if consumed.contains(i) { i += 1; continue }
            let prev = i > 0 && !consumed.contains(i - 1) ? words[i - 1].lowercased() : nil
            if let (date, len) = DatePhrase.match(words, at: i, prev: prev, skip: consumed, now: now, calendar: calendar, defaultHour: defaultHour),
               result.due == nil {
                var start = i
                // A leading "on"/"by"/"due" belongs to the date.
                if start > 0, !consumed.contains(start - 1), ["on", "by", "due", "at"].contains(words[start - 1].lowercased()) { start -= 1 }
                let range = start..<(i + len)
                let typed = range.map { words[$0] }.joined(separator: " ")
                for j in range { consumed.insert(j) }
                result.due = date
                result.tokens.append(Token(kind: .due, text: typed, display: formatDue(date, now: now, calendar: calendar)))
                i += len
                continue
            }
            i += 1
        }

        let title = words.enumerated().filter { !consumed.contains($0.offset) }.map(\.element).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        result.title = title.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : title
        return result
    }

    // MARK: matching

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Exact (normalized) match, else the only prefix match, else the shortest prefix match.
    static func best<T>(_ query: String, in items: [T], by name: KeyPath<T, String>) -> T? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        if let exact = items.first(where: { normalize($0[keyPath: name]) == q }) { return exact }
        let prefixed = items.filter { normalize($0[keyPath: name]).hasPrefix(q) }
        return prefixed.min { normalize($0[keyPath: name]).count < normalize($1[keyPath: name]).count }
    }

    static func member(_ q: String, in users: [User]) -> User? {
        let n = normalize(q)
        guard !n.isEmpty else { return nil }
        if let u = users.first(where: { $0.username.map(normalize) == n }) { return u }
        if let u = users.first(where: { normalize($0.name ?? "") == n }) { return u }
        if let u = users.first(where: { ($0.name ?? "").split(separator: " ").first.map { normalize(String($0)) } == n }) { return u }
        let prefixed = users.filter { normalize($0.name ?? "").hasPrefix(n) || ($0.username.map(normalize)?.hasPrefix(n) ?? false) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    static func label(_ q: String, in labels: [Label]) -> Label? {
        if let l = best(q, in: labels.filter { !$0.name.isEmpty }, by: \.name) { return l }
        let n = normalize(q)
        return labels.first { $0.name.isEmpty && normalize($0.color ?? "") == n }
    }

    /// Merge `#"Two words"` back into one word.
    static func joinQuoted(_ words: inout [String]) {
        var i = 0
        while i < words.count {
            if words[i].hasPrefix("#\""), !(words[i].count > 2 && words[i].hasSuffix("\"")) {
                var j = i + 1
                while j < words.count, !words[j].hasSuffix("\"") { j += 1 }
                if j < words.count {
                    words[i] = words[i...j].joined(separator: " ")
                    words.removeSubrange((i + 1)...j)
                }
            }
            i += 1
        }
    }

    public static func formatDue(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let time = calendar.component(.minute, from: d) == 0 ? "ha" : "h:mma"
        if calendar.isDate(d, inSameDayAs: now) { f.dateFormat = "'Today' \(time)" }
        else if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) { f.dateFormat = "'Tomorrow' \(time)" }
        else if d.timeIntervalSince(now) < 6 * 86_400, d > now { f.dateFormat = "EEE \(time)" }
        else if calendar.component(.year, from: d) == calendar.component(.year, from: now) { f.dateFormat = "MMM d \(time)" }
        else { f.dateFormat = "MMM d yyyy \(time)" }
        return f.string(from: d).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }
}

/// Natural-language dates, English only.
enum DatePhrase {
    static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3, "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]
    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5,
        "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    /// A date starting at `i`, and how many words it used.
    /// Abbreviations that are also ordinary words; only dates after "on", "by", "due", "next" or "this".
    static let ambiguous: Set<String> = ["sat", "sun", "wed", "mar", "may"]
    static let datePrepositions: Set<String> = ["on", "by", "due", "next", "this"]

    /// A date starting at `i`, and how many words it used. `prev` is the word before, if unconsumed.
    static func match(_ raw: [String], at i: Int, prev: String? = nil, skip: Set<Int>, now: Date, calendar cal: Calendar, defaultHour: Int) -> (Date, Int)? {
        // Words up to the next consumed one, lowercased, trailing punctuation dropped.
        var w: [String] = []
        var k = i
        while k < raw.count, !skip.contains(k), w.count < 5 {
            w.append(raw[k].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;!?")))
            k += 1
        }
        guard !w.isEmpty else { return nil }
        let today = cal.startOfDay(for: now)

        func day(_ d: Date, _ n: Int) -> (Date, Int) {
            // Optional time right after the day.
            if n < w.count, let (h, m, used) = time(w, at: n) {
                return (cal.date(bySettingHour: h, minute: m, second: 0, of: d)!, n + used)
            }
            return (cal.date(bySettingHour: defaultHour, minute: 0, second: 0, of: d)!, n)
        }

        switch w[0] {
        case "today": return day(today, 1)
        case "tonight": return (cal.date(bySettingHour: 20, minute: 0, second: 0, of: today)!, 1)
        case "tomorrow", "tmr", "tmrw", "tomorow": return day(cal.date(byAdding: .day, value: 1, to: today)!, 1)
        case "noon": return (cal.date(bySettingHour: 12, minute: 0, second: 0, of: today)!, 1)
        case "weekend":
            return day(nextWeekday(7, after: today, cal: cal), 1)
        default: break
        }

        if w[0] == "this", w.count > 1 {
            if w[1] == "weekend" { return day(nextWeekday(7, after: today, cal: cal, includeToday: true), 2) }
            if let wd = weekdays[w[1]] { return day(nextWeekday(wd, after: today, cal: cal, includeToday: true), 2) }
        }

        if w[0] == "next", w.count > 1 {
            switch w[1] {
            case "week": return day(nextWeekday(2, after: today, cal: cal), 2)
            case "month":
                let m = cal.date(byAdding: .month, value: 1, to: today)!
                return day(cal.date(from: cal.dateComponents([.year, .month], from: m))!, 2)
            case "weekend": return day(nextWeekday(7, after: today, cal: cal), 2)
            default:
                if let wd = weekdays[w[1]] { return day(nextWeekday(wd, after: today, cal: cal), 2) }
            }
        }

        let guarded = prev.map { datePrepositions.contains($0) } ?? false
        if let wd = weekdays[w[0]], !ambiguous.contains(w[0]) || guarded { return day(nextWeekday(wd, after: today, cal: cal), 1) }

        // in 3 days / in 2 weeks / in 1 month / in 4 hours / in 30 mins
        if w[0] == "in", w.count >= 3, let n = Int(w[1]) ?? numberWord(w[1]), n > 0, n < 1000 {
            let unit = w[2].hasSuffix("s") && w[2].count > 1 ? String(w[2].dropLast()) : w[2]
            switch unit {
            case "day": return day(cal.date(byAdding: .day, value: n, to: today)!, 3)
            case "week", "wk": return day(cal.date(byAdding: .day, value: 7 * n, to: today)!, 3)
            case "month", "mo": return day(cal.date(byAdding: .month, value: n, to: today)!, 3)
            case "year", "yr": return day(cal.date(byAdding: .year, value: n, to: today)!, 3)
            case "hour", "hr", "h": return (now.addingTimeInterval(Double(n) * 3600), 3)
            case "min", "minute", "m": return (now.addingTimeInterval(Double(n) * 60), 3)
            default: break
            }
        }

        // 2026-12-01
        if w[0].count == 10, w[0].dropFirst(4).first == "-" {
            let p = w[0].split(separator: "-").compactMap { Int($0) }
            if p.count == 3, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) { return day(d, 1) }
        }

        // jan 5 [2027] / 5 jan [2027] / january 5th
        if let mo = months[w[0]], !ambiguous.contains(w[0]) || guarded || w[0].count > 3, w.count > 1, let dd = ordinal(w[1]) {
            var used = 2
            var year: Int?
            if w.count > 2, let y = Int(w[2]), y >= 2000, y < 2200 { year = y; used = 3 }
            if let d = calendarDate(mo, dd, year, today: today, cal: cal) { return day(d, used) }
        }
        if let dd = ordinal(w[0]), w.count > 1, let mo = months[w[1]] {
            var used = 2
            var year: Int?
            if w.count > 2, let y = Int(w[2]), y >= 2000, y < 2200 { year = y; used = 3 }
            if let d = calendarDate(mo, dd, year, today: today, cal: cal) { return day(d, used) }
        }

        // A bare time: today, or tomorrow if it's already passed.
        // (`time` only accepts unambiguous times: am/pm, a colon, noon or midnight.)
        if let (h, m, used) = time(w, at: 0) {
            var d = cal.date(bySettingHour: h, minute: m, second: 0, of: today)!
            if d <= now { d = cal.date(byAdding: .day, value: 1, to: d)! }
            return (d, used)
        }
        return nil
    }

    /// "5pm", "5:30pm", "5 pm", "17:00", "noon", optionally after "at". Returns hour, minute, words used.
    static func time(_ w: [String], at i: Int) -> (Int, Int, Int)? {
        guard i < w.count else { return nil }
        var j = i
        if w[j] == "at", j + 1 < w.count { j += 1 }
        let lead = j - i
        let s = w[j]
        if s == "noon" { return (12, 0, lead + 1) }
        if s == "midnight" { return (23, 59, lead + 1) }
        var body = s
        var meridiem: String?
        if body.hasSuffix("am") || body.hasSuffix("pm") {
            meridiem = String(body.suffix(2))
            body = String(body.dropLast(2))
        } else if j + 1 < w.count, ["am", "pm"].contains(w[j + 1]), Int(body.split(separator: ":").first ?? "") != nil {
            meridiem = w[j + 1]
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let h = Int(parts[0]), parts[0].count <= 2 else { return nil }
        let m = parts.count == 2 ? Int(parts[1]) : 0
        guard let m, (0..<60).contains(m) else { return nil }
        let usedMeridiemWord = meridiem != nil && !s.hasSuffix(meridiem!)
        let used = lead + 1 + (usedMeridiemWord ? 1 : 0)
        if let meridiem {
            guard (1...12).contains(h) else { return nil }
            let h24 = meridiem == "am" ? (h == 12 ? 0 : h) : (h == 12 ? 12 : h + 12)
            return (h24, m, used)
        }
        // 24-hour needs a colon ("17:00"); a lone "5" is too ambiguous.
        guard parts.count == 2, (0..<24).contains(h) else { return nil }
        return (h, m, used)
    }

    static func ordinal(_ s: String) -> Int? {
        var t = s
        for suf in ["st", "nd", "rd", "th"] where t.hasSuffix(suf) { t = String(t.dropLast(2)) }
        guard let n = Int(t), (1...31).contains(n) else { return nil }
        return n
    }

    static func numberWord(_ s: String) -> Int? {
        ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10][s]
    }

    /// Month/day this year, or next year if it's already gone (unless a year was given).
    static func calendarDate(_ month: Int, _ day: Int, _ year: Int?, today: Date, cal: Calendar) -> Date? {
        let y = year ?? cal.component(.year, from: today)
        guard let d = cal.date(from: DateComponents(year: y, month: month, day: day)),
              cal.component(.day, from: d) == day else { return nil }
        if year == nil, d < today { return cal.date(from: DateComponents(year: y + 1, month: month, day: day)) }
        return d
    }

    /// The next given weekday (1 = Sunday) strictly after `day`, or including it.
    static func nextWeekday(_ wd: Int, after day: Date, cal: Calendar, includeToday: Bool = false) -> Date {
        let current = cal.component(.weekday, from: day)
        var diff = (wd - current + 7) % 7
        if diff == 0, !includeToday { diff = 7 }
        return cal.date(byAdding: .day, value: diff, to: day)!
    }
}
