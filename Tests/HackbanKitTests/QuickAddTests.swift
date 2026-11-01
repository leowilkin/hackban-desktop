import Foundation
import XCTest
@testable import HackbanKit

final class QuickAddTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    /// Sunday 1 Nov 2026, 15:30 London.
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 15, minute: 30))! }

    let boards: [QuickAddParser.Board] = [
        .init(
            key: "work|b1", name: "Product Roadmap",
            lists: [.init(id: "l1", name: "To Do"), .init(id: "l2", name: "Doing"), .init(id: "l3", name: "Done")],
            labels: [Label(id: "lb1", name: "Urgent", color: "red"), Label(id: "lb2", name: "", color: "green")],
            members: [User(id: "u1", name: "Leo Wilkin", username: "leo"), User(id: "u2", name: "Sam Poder", username: "sampoder")],
            meId: "u1"
        ),
        .init(key: "home|b2", name: "Groceries", lists: [.init(id: "g1", name: "Need")]),
        .init(key: "home|b3", name: "Product Ideas", lists: [.init(id: "p1", name: "Inbox")]),
    ]

    func parse(_ s: String, defaultBoard: String? = nil) -> QuickAddParser.Result {
        QuickAddParser.parse(s, boards: boards, defaultBoard: defaultBoard, now: now, calendar: cal, defaultHour: 12)
    }

    func date(_ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, year: Int = 2026) -> Date {
        cal.date(from: DateComponents(year: year, month: m, day: d, hour: h, minute: min))!
    }

    func testEverything() {
        let r = parse("Write launch post #productroadmap /doing @me @sam !urgent tomorrow 5pm")
        XCTAssertEqual(r.title, "Write launch post")
        XCTAssertEqual(r.boardKey, "work|b1")
        XCTAssertEqual(r.listId, "l2")
        XCTAssertEqual(r.memberIds, ["u1", "u2"])
        XCTAssertEqual(r.labelIds, ["lb1"])
        XCTAssertEqual(r.due, date(11, 2, 17))
        XCTAssertEqual(r.tokens.map(\.kind), [.board, .list, .member, .member, .label, .due])
        XCTAssertEqual(r.tokens.last?.display, "Tomorrow 5pm")
    }

    func testBoardSlashList() {
        let r = parse("milk #groceries/need")
        XCTAssertEqual(r.boardKey, "home|b2")
        XCTAssertEqual(r.listId, "g1")
        XCTAssertEqual(r.title, "milk")
    }

    func testQuotedBoardAndExactBeatsPrefix() {
        XCTAssertEqual(parse(#"idea #"Product Ideas""#).boardKey, "home|b3")
        // "product" prefixes both; the shorter name wins.
        XCTAssertEqual(parse("x #product").boardKey, "home|b3")
        XCTAssertEqual(parse("x #productr").boardKey, "work|b1")
    }

    func testUnknownTokensStayInTitle() {
        let r = parse("Fix #123 bug for @nobody !wat", defaultBoard: "work|b1")
        XCTAssertEqual(r.title, "Fix #123 bug for @nobody !wat")
        XCTAssertNil(r.boardKey)
        XCTAssertTrue(r.tokens.isEmpty)
    }

    func testDefaultBoardResolvesListMembersLabels() {
        let r = parse("thing /todo !green @leo", defaultBoard: "work|b1")
        XCTAssertNil(r.boardKey)
        XCTAssertEqual(r.listId, "l1")
        XCTAssertEqual(r.labelIds, ["lb2"])
        XCTAssertEqual(r.memberIds, ["u1"])
        XCTAssertEqual(r.title, "thing")
    }

    func testDates() {
        XCTAssertEqual(parse("a today").due, date(11, 1, 12))
        XCTAssertEqual(parse("a tonight").due, date(11, 1, 20))
        XCTAssertEqual(parse("a fri").due, date(11, 6, 12))
        XCTAssertEqual(parse("a on friday at 9:15am").due, date(11, 6, 9, 15))
        XCTAssertEqual(parse("a next week").due, date(11, 2, 12))
        XCTAssertEqual(parse("a next month").due, date(12, 1, 12))
        XCTAssertEqual(parse("a in 3 days").due, date(11, 4, 12))
        XCTAssertEqual(parse("a in two weeks").due, date(11, 15, 12))
        XCTAssertEqual(parse("a jan 5").due, date(1, 5, 12, year: 2027))
        XCTAssertEqual(parse("a 5th december 17:30").due, date(12, 5, 17, 30))
        XCTAssertEqual(parse("a 2026-12-24").due, date(12, 24, 12))
        XCTAssertEqual(parse("a by dec 1 2027").due, date(12, 1, 12, year: 2027))
        // Bare times: today, or tomorrow once passed.
        XCTAssertEqual(parse("call 5pm").due, date(11, 1, 17))
        XCTAssertEqual(parse("call 9am").due, date(11, 2, 9))
        XCTAssertEqual(parse("call at 6 pm").due, date(11, 1, 18))
        XCTAssertEqual(parse("call at 6 pm").title, "call")
        XCTAssertEqual(parse("a by tomorrow").title, "a")
    }

    func testAmbiguousWordsAreLeftAlone() {
        XCTAssertNil(parse("Sat down with Sam").due)
        XCTAssertNil(parse("fix sun icon").due)
        XCTAssertNil(parse("we may 2 things").due)
        XCTAssertNil(parse("Q3 review").due)
        XCTAssertNil(parse("Call at 5").due)
        XCTAssertEqual(parse("brunch on sat").due, date(11, 7, 12))
        XCTAssertEqual(parse("Q3 review").title, "Q3 review")
    }

    func testOnlyFirstDateCounts() {
        let r = parse("move meeting from mon to fri")
        XCTAssertEqual(r.due, date(11, 2, 12))
        XCTAssertEqual(r.title, "move meeting from to fri")
    }

    func testTitleNeverEmpty() {
        XCTAssertEqual(parse("tomorrow").title, "tomorrow")
    }
}
