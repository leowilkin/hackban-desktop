import AppKit
import Foundation
import HackbanKit
import Observation
import SwiftUI
import UserNotifications

enum Route: Hashable {
    case home
    case myCards
    case notifications
    case search
    case board(account: String, id: String)
    case workspace(account: String, id: String)
    case profile(account: String)
    case closedBoards(account: String)
}

/// A card to show in the card sheet.
struct CardRef: Identifiable, Hashable {
    let account: String
    let cardId: String
    var id: String { "\(account)|\(cardId)" }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var accounts: [Account] = []
    var route: Route? = .home
    /// Card sheet over whatever's showing.
    var openCard: CardRef?
    var toast: String?
    var searchText = ""
    var showPalette = false
    var addingAccount = false
    var signInError: String?

    @ObservationIgnored private var boardModels: [String: BoardModel] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    var visibleAccounts: [Account] { accounts.filter { !$0.config.hidden } }
    var totalUnread: Int { visibleAccounts.reduce(0) { $0 + $1.unread } }

    init() {
        let configs = (try? JSONDecoder().decode([AccountConfig].self, from: defaults.data(forKey: "hackban:accounts") ?? Data())) ?? []
        accounts = configs.map { Account(config: $0, credentials: Keychain.load($0.id)) }
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    func save() {
        if let data = try? JSONEncoder().encode(accounts.map(\.config)) { defaults.set(data, forKey: "hackban:accounts") }
    }

    // MARK: accounts

    func addAccount(server raw: String, label: String) async {
        signInError = nil
        do {
            let server = try OAuth.normalizeServer(raw)
            let creds = try await SignIn().run(server: server, http: URLSessionHTTP())
            // Signing in to a server we already have replaces that account's tokens.
            if let existing = accounts.first(where: { $0.config.server == server }) {
                await existing.tokens.set(creds)
                existing.signedOut = false
                await existing.refresh()
            } else {
                let config = AccountConfig(id: UUID().uuidString, server: server, label: label.isEmpty ? (server.host ?? "Hackban") : label, colorIndex: accounts.count)
                Keychain.save(config.id, creds)
                let a = Account(config: config, credentials: creds)
                accounts.append(a)
                save()
                await a.refresh()
            }
            addingAccount = false
        } catch {
            if (error as? HackbanError) != .cancelled { signInError = error.localizedDescription }
        }
    }

    func reauthenticate(_ a: Account) async {
        do {
            let creds = try await SignIn().run(server: a.config.server, http: URLSessionHTTP())
            await a.tokens.set(creds)
            a.signedOut = false
            a.lastError = nil
            await a.refresh()
        } catch {
            if (error as? HackbanError) != .cancelled { flash(error.localizedDescription) }
        }
    }

    func signOut(_ a: Account) async {
        await a.tokens.set(nil)
        a.signedOut = true
        a.workspaces = []
        a.notifications = []
        a.myCards = []
    }

    func remove(_ a: Account) async {
        await signOut(a)
        accounts.removeAll { $0.id == a.id }
        boardModels = boardModels.filter { $0.value.account.id != a.id }
        save()
        if case .board(let acc, _)? = route, acc == a.id { route = .home }
    }

    // MARK: boards

    func boardModel(account: Account, boardId: String) -> BoardModel {
        let key = "\(account.id)|\(boardId)"
        if let m = boardModels[key] { return m }
        let m = BoardModel(app: self, account: account, boardId: boardId)
        boardModels[key] = m
        return m
    }

    func open(board id: String, in account: Account) {
        route = .board(account: account.id, id: id)
    }

    func open(card id: String, in account: Account, board boardId: String? = nil) {
        if let boardId { route = .board(account: account.id, id: boardId) }
        openCard = CardRef(account: account.id, cardId: id)
    }

    // MARK: refresh & notifications

    func start() {
        Task { await refreshAll() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await self?.pollNotifications()
            }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { g in
            for a in accounts where !a.signedOut { g.addTask { await a.refresh() } }
        }
        seedSeenNotifications()
        updateBadge()
    }

    private func seenKey(_ a: Account) -> String { "hackban:seen-notifications:\(a.id)" }

    /// Don't announce what was already there on launch.
    private func seedSeenNotifications() {
        for a in accounts where defaults.array(forKey: seenKey(a)) == nil {
            defaults.set(a.notifications.map(\.id), forKey: seenKey(a))
        }
    }

    func pollNotifications() async {
        for a in visibleAccounts where !a.signedOut {
            await a.refreshNotifications()
            let seen = Set(defaults.stringArray(forKey: seenKey(a)) ?? [])
            let fresh = a.notifications.filter { !$0.read && !seen.contains($0.id) }
            if defaults.object(forKey: "hackban:notify") as? Bool ?? true {
                for n in fresh { deliver(n, account: a) }
            }
            defaults.set(Array((seen.union(a.notifications.map(\.id))).prefix(500)), forKey: seenKey(a))
        }
        updateBadge()
    }

    private func deliver(_ n: HackbanNotification, account: Account) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = accounts.count > 1 ? "Hackban · \(account.config.label)" : "Hackban"
        content.body = n.summary
        if let text = n.data["text"] { content.subtitle = text }
        content.userInfo = ["account": account.id, "card": n.cardId ?? "", "board": n.boardId ?? "", "notification": n.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(account.id)|\(n.id)", content: content, trigger: nil))
    }

    func updateBadge() {
        let n = totalUnread
        NSApp?.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    func markRead(_ n: HackbanNotification, in a: Account) {
        if let i = a.notifications.firstIndex(where: { $0.id == n.id }) { a.notifications[i].read = true }
        updateBadge()
        run(a) { try await a.api.markRead(n.id) }
    }

    func markAllRead() {
        for a in visibleAccounts where a.unread > 0 {
            for i in a.notifications.indices { a.notifications[i].read = true }
            run(a) { try await a.api.markAllRead() }
        }
        updateBadge()
    }

    // MARK: errors

    func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if toast == message { toast = nil }
        }
    }

    /// Run a mutation, reporting failures as a toast.
    func run(_ account: Account, _ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch {
                account.handle(error)
                if (error as? HackbanError) != .cancelled { flash(error.localizedDescription) }
            }
        }
    }
}
