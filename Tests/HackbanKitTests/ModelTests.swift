import Foundation
import XCTest
@testable import HackbanKit

final class ModelTests: XCTestCase {
    /// Trimmed from a real `board.get` response.
    let boardJSON = #"""
    {"result":{"data":{"json":{
      "id":"b1","name":"Launch","description":null,"workspaceId":"w1","background":"linear-gradient(135deg, #0c66e4 0%, #37b4c3 100%)",
      "bgImage":null,"visibility":"workspace","closed":false,"inviteRole":"normal","trelloId":null,
      "createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-02T10:00:00.000Z",
      "workspace":{"id":"w1","name":"Hack Club"},
      "members":[{"boardId":"b1","userId":"u1","role":"admin","lastViewed":"2026-10-30T10:00:00.000Z",
        "user":{"id":"u1","name":"Leo Wilkin","image":null,"username":"leo","isGhost":false,"invitedEmail":null},"guest":false}],
      "labels":[{"id":"l1","boardId":"b1","name":"Urgent","color":"red","trelloId":null},{"id":"l2","boardId":"b1","name":"","color":"green_light","trelloId":null}],
      "lists":[{"id":"li1","boardId":"b1","name":"To Do","pos":"a0","color":null,"closed":false,"trelloId":null,"createdAt":"2026-10-01T10:00:00.000Z",
        "cards":[{"id":"c1","listId":"li1","title":"Write post","description":"","pos":"a0","start":null,"due":"2026-11-02T17:00:00.000Z",
          "dueComplete":false,"recurrence":null,"coverColor":null,"coverAttachmentId":null,"coverSize":"normal","closed":false,"trelloId":null,
          "shortId":3,"createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z",
          "labels":[{"cardId":"c1","labelId":"l1","label":{"id":"l1","boardId":"b1","name":"Urgent","color":"red","trelloId":null}}],
          "members":[{"cardId":"c1","userId":"u1","user":{"id":"u1","name":"Leo Wilkin","image":null}}],
          "_count":{"comments":2,"attachments":1},
          "blockedBy":[{"blocker":{"title":"Design"}}],"blocking":[],
          "issues":[{"id":"gi1","owner":"hackclub","repo":"hackban","number":4,"state":"open","title":"Track issues","fetchError":null}],
          "watching":true,"checkTotal":4,"checkDone":1,"coverUrl":null}]}],
      "inviteToken":"tok","starred":true,"myRole":"admin"
    },"meta":{"values":{"createdAt":["Date"]}}}}}
    """#

    func testBoardDecodes() throws {
        let b: Board = try TRPCClient.decode(Data(boardJSON.utf8), status: 200)
        XCTAssertEqual(b.name, "Launch")
        XCTAssertEqual(b.lists.count, 1)
        let c = b.lists[0].openCards[0]
        XCTAssertEqual(c.title, "Write post")
        XCTAssertEqual(c.labelIds, ["l1"])
        XCTAssertEqual(c.commentCount, 2)
        XCTAssertEqual(c.checkCounts.done, 1)
        XCTAssertEqual(c.checkCounts.total, 4)
        XCTAssertEqual(c.blockedByTitles, ["Design"])
        XCTAssertTrue(c.isBlocked)
        XCTAssertFalse(c.isBlocking)
        XCTAssertEqual(c.watching, true)
        XCTAssertTrue(c.tracksIssues)
        XCTAssertEqual(c.trackedIssues.map(\.label), ["hackclub/hackban#4"])
        XCTAssertFalse(c.trackedIssues[0].isClosed)
        XCTAssertTrue(b.isAdmin)
        XCTAssertEqual(Palette.backgroundStops(b.background), ["#0c66e4", "#37b4c3"])
        XCTAssertEqual(b.list(containing: "c1")?.cardIndex, 0)
    }

    func testCardDetailDecodes() throws {
        let json = #"""
        {"result":{"data":{"json":{"id":"c1","listId":"li1","title":"T","description":"**hi**","pos":"a0","start":null,"due":null,
        "dueComplete":false,"recurrence":"weekly","coverColor":"blue","coverAttachmentId":null,"coverSize":"full","closed":false,"shortId":1,
        "createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z",
        "list":{"id":"li1","name":"To Do","boardId":"b1","board":{"name":"Launch"}},
        "labels":[],"members":[],
        "checklists":[{"id":"k1","cardId":"c1","name":"Steps","pos":"a0","trelloId":null,"items":[
          {"id":"i1","checklistId":"k1","name":"One","pos":"a0","complete":true,"due":null,"memberId":null,"trelloId":null,"member":null}]}],
        "attachments":[{"id":"a1","cardId":"c1","uploaderId":"u1","name":"x.png","url":"/api/files/a1","mimeType":"image/png","size":12,
          "isUpload":true,"storageKey":"k","trelloId":null,"createdAt":"2026-10-01T10:00:00.000Z","uploader":{"id":"u1","name":"Leo","image":null,"username":null}}],
        "comments":[{"id":"m1","cardId":"c1","authorId":"u1","text":"hey","trelloId":null,"createdAt":"2026-10-01T10:00:00.000Z","editedAt":null,
          "author":{"id":"u1","name":"Leo","image":null,"username":null}}],
        "activities":[{"id":"ac1","boardId":"b1","cardId":"c1","actorId":"u1","type":"changeDue","data":{"title":"T","due":"2026-11-02T17:00:00.000Z","recurrence":null},
          "createdAt":"2026-10-01T10:00:00.000Z","actor":{"id":"u1","name":"Leo","image":null,"username":null}},
          {"id":"ac2","boardId":"b1","cardId":"c1","actorId":"u1","type":"githubIssueClosed","data":{"title":"T","issue":"hackclub/hackban#4","closedBy":"octocat"},
          "createdAt":"2026-10-02T10:00:00.000Z","actor":{"id":"u1","name":"Leo","image":null,"username":null}}],
        "issues":[{"id":"gi1","cardId":"c1","owner":"hackclub","repo":"hackban","number":4,"title":"Track issues","state":"closed","stateReason":"completed",
          "closedBy":"octocat","closedAt":"2026-10-02T09:00:00.000Z","checkedAt":"2026-10-02T09:30:00.000Z","fetchError":null,"completedCardAt":"2026-10-02T09:30:00.000Z",
          "addedById":"u1","createdAt":"2026-10-01T10:00:00.000Z"},
          {"id":"gi2","cardId":"c1","owner":"hackclub","repo":"secret","number":9,"title":"","state":"open","stateReason":null,"closedBy":null,"closedAt":null,
          "checkedAt":"2026-10-02T09:30:00.000Z","fetchError":"not_found","completedCardAt":null,"addedById":null,"createdAt":"2026-10-01T10:00:00.000Z"}],
        "watching":false,
        "blockedBy":[{"id":"c2","title":"Design","dueComplete":false},{"id":"c3","title":"Done one","dueComplete":true}],
        "blocking":[{"id":"c4","title":"Ship","dueComplete":false}]
        }}}}
        """#
        let c: Card = try TRPCClient.decode(Data(json.utf8), status: 200)
        XCTAssertEqual(c.checklists?.first?.done, 1)
        XCTAssertEqual(c.attachments?.first?.isImage, true)
        XCTAssertEqual(c.comments?.first?.author?.name, "Leo")
        XCTAssertEqual(c.blockers.map(\.id), ["c2", "c3"])
        XCTAssertEqual(c.blockedByTitles, ["Design"])
        XCTAssertEqual(c.blocks.map(\.title), ["Ship"])
        XCTAssertEqual(c.list?.board?.name, "Launch")
        let a = c.activities![0]
        XCTAssertTrue(ActivityText.describe(a, onCard: true).hasPrefix("set this card to be due "))
        XCTAssertEqual(ActivityText.describe(c.activities![1], onCard: true), "completed this card because GitHub issue hackclub/hackban#4 was closed by @octocat")
        let issues = c.trackedIssues
        XCTAssertEqual(issues.map(\.id), ["gi1", "gi2"])
        XCTAssertTrue(issues[0].isClosed)
        XCTAssertEqual(issues[0].closedAt, ISODate.parse("2026-10-02T09:00:00Z"))
        XCTAssertEqual(issues[0].displayTitle, "Track issues")
        XCTAssertEqual(issues[0].url.absoluteString, "https://github.com/hackclub/hackban/issues/4")
        XCTAssertTrue(issues[1].isUnreadable)
        XCTAssertEqual(issues[1].displayTitle, "hackclub/secret#9")
    }

    func testGitHubIssueLinksParse() {
        XCTAssertEqual(GitHubIssueRef.parse("https://github.com/hackclub/hackban/issues/4"), GitHubIssueRef(owner: "hackclub", repo: "hackban", number: 4))
        XCTAssertEqual(GitHubIssueRef.parse("  HTTP://www.github.com/a-b/c.d/issues/12/?x=1#top \n"), GitHubIssueRef(owner: "a-b", repo: "c.d", number: 12))
        XCTAssertNil(GitHubIssueRef.parse("https://github.com/hackclub/hackban/pull/4"), "pull requests aren't tracked")
        XCTAssertNil(GitHubIssueRef.parse("https://github.com/hackclub/hackban/issues"))
        XCTAssertNil(GitHubIssueRef.parse("https://github.com/hackclub/hackban/issues/0"))
        XCTAssertNil(GitHubIssueRef.parse("https://gitlab.com/hackclub/hackban/issues/4"))
        XCTAssertNil(GitHubIssueRef.parse("https://github.com/hackclub/hackban/issues/4/comments"))
        XCTAssertEqual(GitHubIssueRef(owner: "o", repo: "r", number: 7).label, "o/r#7")
    }

    func testCardWithoutIssuesFieldIsFromAnOlderServer() throws {
        let b: Board = try TRPCClient.decode(Data(boardJSON.replacingOccurrences(of: #""issues":[{"id":"gi1","owner":"hackclub","repo":"hackban","number":4,"state":"open","title":"Track issues","fetchError":null}],"#, with: "").utf8), status: 200)
        let c = b.lists[0].openCards[0]
        XCTAssertFalse(c.tracksIssues)
        XCTAssertEqual(c.trackedIssues, [])
    }

    func testNotificationsAndWorkspaces() throws {
        let n: [HackbanNotification] = try TRPCClient.decode(Data(#"""
        {"result":{"data":{"json":[{"id":"n1","userId":"u1","type":"commentCard","data":{"cardId":"c1","title":"Write post","boardId":"b1","by":"Sam","text":"hi"},"read":false,"createdAt":"2026-10-01T10:00:00.000Z"}]}}}
        """#.utf8), status: 200)
        XCTAssertEqual(n[0].summary, "Sam commented on the card Write post")
        XCTAssertEqual(n[0].cardId, "c1")

        let w: [Workspace] = try TRPCClient.decode(Data(#"""
        {"result":{"data":{"json":[{"id":"w1","name":"Hack Club","description":null,"logoKey":null,"trelloId":null,"createdAt":"2026-10-01T10:00:00.000Z","logo":null,
        "boards":[{"id":"b1","name":"Launch","description":null,"workspaceId":"w1","background":"#0079bf","bgImage":null,"visibility":"workspace","closed":false,
        "inviteRole":"normal","trelloId":null,"createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z","starred":false}]}]}}}
        """#.utf8), status: 200)
        XCTAssertEqual(w[0].boards[0].name, "Launch")
    }

    func testFiltersAndSorts() throws {
        let b: Board = try TRPCClient.decode(Data(boardJSON.utf8), status: 200)
        var c = b.lists[0].openCards[0]
        let now = ISODate.parse("2026-11-02T12:00:00Z")!
        var f = CardFilters()
        XCTAssertFalse(f.isActive)
        f.query = "WRITE"
        XCTAssertTrue(f.matches(c, now: now))
        f.query = ""
        f.labels = ["none"]
        XCTAssertFalse(f.matches(c, now: now))
        f.labels = ["l1"]
        XCTAssertTrue(f.matches(c, now: now))
        f.due = [.day]
        XCTAssertTrue(f.matches(c, now: now))
        f.due = [.overdue]
        XCTAssertFalse(f.matches(c, now: now))
        c.dueComplete = true
        f.due = [.complete]
        XCTAssertTrue(f.matches(c, now: now))

        var a = c, z = c
        a.title = "item 2"; a.due = nil
        z.title = "item 10"; z.due = now
        XCTAssertEqual(CardSort.nameAZ.sorted([z, a]).map(\.title), ["item 2", "item 10"])
        XCTAssertEqual(CardSort.dueSoonest.sorted([a, z]).map(\.title), ["item 10", "item 2"])
    }

    func testPatchAppliesLocally() throws {
        let b: Board = try TRPCClient.decode(Data(boardJSON.utf8), status: 200)
        var c = b.lists[0].openCards[0]
        HackbanAPI.CardPatch(title: "New", due: .some(nil), coverColor: .some("blue")).apply(to: &c)
        XCTAssertEqual(c.title, "New")
        XCTAssertNil(c.due)
        XCTAssertEqual(c.coverColor, "blue")
        XCTAssertNil(c.coverAttachmentId)
    }

    func testPalette() {
        XCTAssertEqual(Palette.label("red", dark: false), .init(background: "#f87168", foreground: "#172b4d"))
        XCTAssertEqual(Palette.label("green_dark", dark: true)?.background, "#4bce97")
        XCTAssertNil(Palette.label(nil, dark: false))
        XCTAssertEqual(Palette.labelColors.count, 30)
        XCTAssertEqual(parseHex("#fff")?.r, 1)
        XCTAssertEqual(parseHex("#0079bf")?.b ?? 0, 191.0 / 255, accuracy: 0.001)
    }
}
