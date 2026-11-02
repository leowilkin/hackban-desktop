import Foundation
import HackbanKit
import Observation
import SwiftUI

/// What's saved about an account in UserDefaults (tokens live in the Keychain).
struct AccountConfig: Codable, Identifiable, Hashable {
    let id: String
    var server: URL
    var label: String
    var colorIndex: Int
    var hidden: Bool = false
}

/// What's kept on disk so the sidebar, Home and My Cards work offline.
struct AccountSnapshot: Codable, Sendable {
    var profile: Profile?
    var workspaces: [Workspace]
    var guestBoards: [BoardSummary]
    var recent: [BoardSummary]
    var notifications: [HackbanNotification]
    var myCards: [Card]
}

/// One signed-in Hackban server.
@MainActor
@Observable
final class Account: Identifiable {
    nonisolated let id: String
    var config: AccountConfig
    let api: HackbanAPI
    let tokens: TokenManager
    /// Offline snapshots and the changes waiting to sync.
    let sync: SyncEngine

    var profile: Profile?
    var workspaces: [Workspace] = []
    var guestBoards: [BoardSummary] = []
    var recent: [BoardSummary] = []
    var notifications: [HackbanNotification] = []
    var myCards: [Card] = []
    var signedOut = false
    var lastError: String?
    var loaded = false
    /// What this Mac kept for the account was forgotten (it was someone else's).
    @ObservationIgnored var onForgotten: (() -> Void)?

    var client: TRPCClient { api.client }
    var me: String? { profile?.id }
    var unread: Int { notifications.filter { !$0.read }.count }
    var color: Color { AccountPalette.color(config.colorIndex) }
    var host: String { config.server.host ?? config.server.absoluteString }

    init(config: AccountConfig, credentials: AccountCredentials?) {
        self.config = config
        self.id = config.id
        let id = config.id
        let http = URLSessionHTTP()
        tokens = TokenManager(credentials: credentials, http: http) { Keychain.save(id, $0) }
        api = HackbanAPI(client: TRPCClient(server: config.server, tokens: tokens, http: http))
        sync = SyncEngine(accountId: id, api: api)
        signedOut = credentials == nil
        sync.account = self
        if let (s, _) = sync.store.load(AccountSnapshot.self, "account.json") {
            profile = s.profile
            workspaces = s.workspaces
            guestBoards = s.guestBoards
            recent = s.recent
            notifications = s.notifications
            myCards = s.myCards
            loaded = true
        }
        sync.setCacheOwner(profile?.id ?? sync.queue.userId)
    }

    /// A profile fetched with the current tokens says who this is. If what's kept on this Mac belonged to
    /// someone else, it's forgotten; then changes made as this user can go.
    func confirmIdentity(_ userId: String) {
        if sync.confirm(userId) == .someoneElse {
            forgetLocalData()
            onForgotten?()
        }
        sync.drain()
    }

    /// New tokens are about to replace this account's. Until a profile fetched with them says who this is,
    /// nothing kept on this Mac is shown or sent.
    func beginSignIn() {
        sync.beginSignIn()
        clearLists()
    }

    /// Takes everything kept for this account off the Mac (and out of memory).
    func forgetLocalData() {
        clearLists()
        sync.wipe()
    }

    private func clearLists() {
        profile = nil
        workspaces = []
        guestBoards = []
        recent = []
        notifications = []
        myCards = []
        loaded = false
    }

    private func saveSnapshot() {
        let s = AccountSnapshot(profile: profile, workspaces: workspaces, guestBoards: guestBoards, recent: recent, notifications: notifications, myCards: myCards)
        sync.store.save(s, "account.json")
    }

    /// Every board this account can open, for pickers.
    var allBoards: [(workspace: String, board: BoardSummary)] {
        workspaces.flatMap { w in w.boards.map { (w.name, $0) } } + guestBoards.map { ($0.workspace?.name ?? "Guest", $0) }
    }

    var starredBoards: [BoardSummary] { allBoards.map(\.board).filter { $0.starred == true } }

    func refresh() async {
        guard !signedOut, !sync.isOffline else { return }
        do {
            async let p = api.profile()
            async let w = api.workspaces()
            async let g = api.guestBoards()
            async let r = api.recentBoards()
            async let n = api.notifications()
            let me = try await p
            confirmIdentity(me.id)
            profile = me
            workspaces = try await w
            guestBoards = try await g
            recent = try await r
            notifications = try await n
            lastError = nil
            loaded = true
            saveSnapshot()
        } catch {
            handle(error)
        }
    }

    func refreshNotifications() async {
        guard !signedOut, !sync.isOffline else { return }
        do {
            notifications = try await api.notifications()
            saveSnapshot()
        } catch {
            handle(error)
        }
    }

    func refreshMyCards() async {
        guard !signedOut, !sync.isOffline else { return }
        do {
            myCards = try await api.myCards()
            saveSnapshot()
        } catch {
            handle(error)
        }
    }

    /// Records a failed request: can't reach the server → offline; revoked tokens → signed out.
    func handle(_ error: Error) {
        switch Reachability.classify(error) {
        case .offline:
            sync.goOffline()
            return
        case .cancelled:
            return
        case .signedOut:
            signedOut = true
        default:
            break
        }
        lastError = error.localizedDescription
    }
}

enum AccountPalette {
    static let colors: [Color] = [.blue, .pink, .green, .orange, .purple, .teal, .red, .indigo]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}
