import AppKit
import Foundation
import HackbanKit
import Network
import Observation
import SwiftUI
import UserNotifications

enum Route: Hashable {
    case home
    case myCards
    case notifications
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
    var addingAccount = false
    var signInError: String?

    @ObservationIgnored private var boardModels: [String: BoardModel] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    private let defaults = UserDefaults.standard

    var visibleAccounts: [Account] { accounts.filter { !$0.config.hidden } }
    var totalUnread: Int { visibleAccounts.reduce(0) { $0 + $1.unread } }

    init() {
        let configs = (try? JSONDecoder().decode([AccountConfig].self, from: defaults.data(forKey: "hackban:accounts") ?? Data())) ?? []
        accounts = configs.map { Account(config: $0, credentials: Keychain.load($0.id)) }
        for a in accounts { wire(a) }
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
                await installSignIn(existing, creds)
            } else {
                let config = AccountConfig(id: UUID().uuidString, server: server, label: label.isEmpty ? (server.host ?? "Hackban") : label, colorIndex: accounts.count)
                Keychain.save(config.id, creds)
                let a = Account(config: config, credentials: creds)
                wire(a)
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
            await installSignIn(a, creds)
        } catch {
            if (error as? HackbanError) != .cancelled { flash(error.localizedDescription) }
        }
    }

    /// New tokens for an account that's already here (signing in again, or adding a server that's already
    /// added). Nothing kept on this Mac for it is shown or sent until a profile fetched with the new tokens says
    /// who this is, and if it's someone else, it's forgotten (`Account.confirmIdentity`). If that can't be
    /// confirmed yet, it stays hidden and held until a later refresh or probe does.
    private func installSignIn(_ a: Account, _ creds: AccountCredentials) async {
        a.beginSignIn()
        await a.tokens.set(creds)
        a.sync.tokensInstalled()
        a.signedOut = false
        a.lastError = nil
        await a.refresh()
        a.sync.resume()
    }

    func signOut(_ a: Account) async {
        await a.tokens.set(nil)
        a.signedOut = true
        // Signing out on purpose takes this server's boards and cards off the Mac too.
        a.forgetLocalData()
        a.sync.forgetIdentity()
    }

    func remove(_ a: Account) async {
        await signOut(a)
        a.sync.wipe()
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
        for a in accounts { a.sync.resume() }
        startNetworkMonitor()
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
        for a in visibleAccounts where !a.signedOut && !a.sync.isOffline {
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
        guard requireOnline(account) else { return }
        Task {
            do { try await op() } catch {
                account.handle(error)
                if (error as? HackbanError) != .cancelled { flash(message(for: error)) }
            }
        }
    }

    /// What to say about a failed request.
    func message(for error: Error) -> String {
        Reachability.classify(error) == .offline ? "Can't reach the server. Changes that work offline are kept until it's back." : error.localizedDescription
    }

    /// False (with a toast) when the account is offline, for things that need the server.
    func requireOnline(_ account: Account) -> Bool {
        guard account.sync.isOffline else { return true }
        flash("You're offline. That needs a connection to \(account.host).")
        return false
    }

    // MARK: offline

    private func wire(_ a: Account) {
        a.sync.onConnectivity = { [weak self, weak a] online in
            guard let self, let a else { return }
            self.connectivityChanged(a, online: online)
        }
        a.sync.onSynced = { [weak self, weak a] boardId, cardId, refresh in
            guard let self, let a else { return }
            self.synced(a, boardId: boardId, cardId: cardId, refresh: refresh)
        }
        a.sync.onMessage = { [weak self] in self?.flash($0) }
        a.onForgotten = { [weak self, weak a] in
            guard let self, let a else { return }
            self.boardModels = self.boardModels.filter { $0.value.account.id != a.id }
            if case .board(let acc, _)? = self.route, acc == a.id { self.route = .home }
        }
    }

    /// Live updates stop while a server's unreachable, and reconnect (refetching what's open) when it's back.
    private func connectivityChanged(_ a: Account, online: Bool) {
        let models = boardModels.values.filter { $0.account === a }
        if online {
            for m in models {
                m.reconnect()
                m.openCard?.scheduleReload()
            }
            Task {
                await a.refresh()
                updateBadge()
            }
        } else {
            for m in models { m.stopLive() }
        }
    }

    /// A queued change reached the server: refetch what it changed, for the parts the server works out
    /// (positions, counts, a repeating card's next date). Our own changes don't come back over live updates.
    private func synced(_ a: Account, boardId: String, cardId: String?, refresh: Bool) {
        guard let m = boardModels["\(a.id)|\(boardId)"] else { return }
        if refresh { m.scheduleReload(after: 600) }
        if let cardId, let open = m.openCard, open.id == cardId { open.scheduleReload(after: 400) }
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in AppModel.shared.networkChanged(up: up) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "hackban.network"))
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.networkChanged(up: true) }
        }
    }

    /// No network: every account is offline. Network back (or the app came to the front): check the
    /// offline ones now instead of at their next backoff.
    func networkChanged(up: Bool) {
        for a in accounts where !a.signedOut {
            if up { a.sync.probeNow() } else { a.sync.goOffline() }
        }
    }
}
