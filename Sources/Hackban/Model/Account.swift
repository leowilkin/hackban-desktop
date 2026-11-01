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

/// One signed-in Hackban server.
@MainActor
@Observable
final class Account: Identifiable {
    nonisolated let id: String
    var config: AccountConfig
    let api: HackbanAPI
    let tokens: TokenManager

    var profile: Profile?
    var workspaces: [Workspace] = []
    var guestBoards: [BoardSummary] = []
    var recent: [BoardSummary] = []
    var notifications: [HackbanNotification] = []
    var myCards: [Card] = []
    var signedOut = false
    var lastError: String?
    var loaded = false

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
        signedOut = credentials == nil
    }

    /// Every board this account can open, for pickers.
    var allBoards: [(workspace: String, board: BoardSummary)] {
        workspaces.flatMap { w in w.boards.map { (w.name, $0) } } + guestBoards.map { ($0.workspace?.name ?? "Guest", $0) }
    }

    var starredBoards: [BoardSummary] { allBoards.map(\.board).filter { $0.starred == true } }

    func refresh() async {
        guard !signedOut else { return }
        do {
            async let p = api.profile()
            async let w = api.workspaces()
            async let g = api.guestBoards()
            async let r = api.recentBoards()
            async let n = api.notifications()
            profile = try await p
            workspaces = try await w
            guestBoards = try await g
            recent = try await r
            notifications = try await n
            lastError = nil
            loaded = true
        } catch {
            handle(error)
        }
    }

    func refreshNotifications() async {
        guard !signedOut else { return }
        do { notifications = try await api.notifications() } catch { handle(error) }
    }

    func refreshMyCards() async {
        guard !signedOut else { return }
        do { myCards = try await api.myCards() } catch { handle(error) }
    }

    func handle(_ error: Error) {
        if let e = error as? HackbanError, e.isAuthFailure { signedOut = true }
        if (error as? HackbanError) == .cancelled { return }
        lastError = error.localizedDescription
    }
}

enum AccountPalette {
    static let colors: [Color] = [.blue, .pink, .green, .orange, .purple, .teal, .red, .indigo]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}
