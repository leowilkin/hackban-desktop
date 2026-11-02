import AppKit
import HackbanKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    let account: Account
    let workspaceId: String
    @Environment(AppModel.self) private var app
    @State private var ws: WorkspaceDetail?
    @State private var tab = 0
    @State private var sort = "recent"
    @State private var q = ""
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        Group {
            if let ws {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        WorkspaceLogo(name: ws.name, logo: ws.logo, account: account, size: 56)
                        VStack(alignment: .leading) {
                            Text(ws.name).font(.title.bold())
                            if let d = ws.description, !d.isEmpty { Text(d).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        AccountTag(account: account)
                    }
                    .padding(20)
                    Picker("", selection: $tab) {
                        Text("Boards").tag(0)
                        Text("Members (\(ws.members.count))").tag(1)
                        Text("Settings").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 20)
                    Divider().padding(.top, 10)
                    switch tab {
                    case 0: boards(ws)
                    case 1: WorkspaceMembers(account: account, ws: ws) { await load() }
                    default: WorkspaceSettings(account: account, ws: ws) { await load() }
                    }
                }
            } else if let error {
                ContentUnavailableView("Couldn't load the workspace", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(ws?.name ?? "Workspace")
        .task { await load() }
        .sheet(isPresented: $creating) { CreateBoardView(account: account, workspaceId: workspaceId).environment(app) }
    }

    private func load() async {
        do { ws = try await account.api.workspace(workspaceId); error = nil } catch { self.error = error.localizedDescription }
    }

    private func boards(_ ws: WorkspaceDetail) -> some View {
        let open = ws.boards.filter { $0.closed != true && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
        let sorted: [BoardSummary] = {
            switch sort {
            case "az": return open.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case "za": return open.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            default: return open.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
            }
        }()
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("Sort by", selection: $sort) {
                        Text("Most recently active").tag("recent")
                        Text("Alphabetically A–Z").tag("az")
                        Text("Alphabetically Z–A").tag("za")
                    }
                    .fixedSize()
                    Spacer()
                    TextField("Search boards", text: $q).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)], alignment: .leading, spacing: 14) {
                    Button { creating = true } label: {
                        Text("Create new board").frame(maxWidth: .infinity, minHeight: 90).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    ForEach(sorted) { b in BoardTile(board: b, account: account) }
                }
                let closed = ws.boards.filter { $0.closed == true }
                if !closed.isEmpty {
                    Button("View closed boards (\(closed.count))") { app.route = .closedBoards(account: account.id) }.buttonStyle(.link)
                }
            }
            .padding(20)
        }
    }
}

private struct WorkspaceMembers: View {
    let account: Account
    let ws: WorkspaceDetail
    let reload: () async -> Void
    @Environment(AppModel.self) private var app
    @State private var q = ""
    @State private var results: [User] = []
    @State private var confirm: ConfirmAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Invite by name, username or email", text: $q).textFieldStyle(.roundedBorder)
                if q.contains("@") && q.contains(".") {
                    Button("Invite \(q)") { act { try await account.api.addWorkspaceMember(ws.id, email: q.trimmingCharacters(in: .whitespaces)) }; q = "" }
                }
            }
            ForEach(results) { u in
                Button {
                    act { try await account.api.addWorkspaceMember(ws.id, userId: u.id) }
                    q = ""
                    results = []
                } label: {
                    HStack { AvatarView(user: u, account: account, size: 22); Text(u.displayName); Spacer(); Text("Add").foregroundStyle(Color.accentColor) }
                }
                .buttonStyle(.plain)
            }
            List {
                ForEach(ws.members, id: \.userId) { m in
                    HStack {
                        AvatarView(user: m.user, account: account, size: 30)
                        VStack(alignment: .leading) {
                            Text(m.user.displayName)
                            if m.user.isGhost == true {
                                Text(m.user.invitedEmail != nil ? "Invited, hasn't logged in yet" : "Imported from Trello").font(.caption).foregroundStyle(.secondary)
                            } else if let e = m.user.email {
                                Text(e).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if ws.isAdmin {
                            Picker("", selection: Binding(get: { m.role }, set: { r in act { try await account.api.addWorkspaceMember(ws.id, userId: m.userId, role: r) } })) {
                                Text("Admin").tag("admin")
                                Text("Member").tag("normal")
                            }
                            .labelsHidden().fixedSize()
                        } else {
                            Text(m.role == "admin" ? "Admin" : "Member").foregroundStyle(.secondary)
                        }
                        if ws.isAdmin || m.userId == account.me {
                            Button(m.userId == account.me ? "Leave" : "Remove") {
                                confirm = ConfirmAction(
                                    title: m.userId == account.me ? "Leave \(ws.name)?" : "Remove \(m.user.displayName)?",
                                    message: "They'll also be removed from this workspace's boards.",
                                    button: m.userId == account.me ? "Leave" : "Remove"
                                ) {
                                    act {
                                        try await account.api.removeWorkspaceMember(ws.id, userId: m.userId)
                                        if m.userId == account.me { await account.refresh(); app.route = .home }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if account.profile?.isAdmin == true, ws.members.contains(where: { $0.user.isGhost == true && $0.user.invitedEmail == nil }) {
                Text("Linking imported Trello members to accounts is a site-admin action in the browser.").font(.caption).foregroundStyle(.secondary)
                Button("Open workspace members in browser") { NSWorkspace.shared.open(account.client.webURL("/w/\(ws.id)/members")) }
            }
        }
        .padding(20)
        .confirm($confirm)
        .task(id: q) {
            let query = q.trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else { results = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            let ids = Set(ws.members.map(\.userId))
            results = ((try? await account.api.searchUsers(query)) ?? []).filter { !ids.contains($0.id) }
        }
    }

    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { app.flash(error.localizedDescription) }
            await reload()
        }
    }
}

private struct WorkspaceSettings: View {
    let account: Account
    let ws: WorkspaceDetail
    let reload: () async -> Void
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var description = ""
    @State private var rules: [AutoJoinRule] = []
    @State private var domain = ""
    @State private var deleteName = ""
    @State private var picking = false

    var body: some View {
        Form {
            Section("Details") {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                Button("Save") {
                    act { try await account.api.updateWorkspace(ws.id, name: name, description: description); await account.refresh() }
                }
                .disabled(!ws.isAdmin)
            }
            Section("Logo") {
                HStack {
                    WorkspaceLogo(name: ws.name, logo: ws.logo, account: account, size: 48)
                    Button("Upload…") { picking = true }
                    if ws.logo != nil { Button("Remove") { act { try await account.api.removeLogo(workspaceId: ws.id); await account.refresh() } } }
                }
                .disabled(!ws.isAdmin)
            }
            Section("Auto-join by email domain") {
                Text("Anyone who logs in with an email on these domains joins this workspace. You can add your own email domain.").font(.caption).foregroundStyle(.secondary)
                ForEach(rules) { r in
                    HStack {
                        Text("@\(r.domain)")
                        Text("\(r.memberCount ?? 0) members").foregroundStyle(.secondary)
                        Spacer()
                        if ws.isAdmin { Button("Remove") { act { try await account.api.removeAutoJoin(ws.id, ruleId: r.id) } } }
                    }
                }
                if ws.isAdmin {
                    HStack {
                        TextField("example.com", text: $domain)
                        Button("Add") { act { try await account.api.addAutoJoin(ws.id, domain: domain) }; domain = "" }.disabled(domain.isEmpty)
                    }
                }
            }
            if ws.isAdmin {
                Section("Delete workspace") {
                    Text("Deletes the workspace and every board in it. Type the workspace name to confirm.").font(.caption).foregroundStyle(.secondary)
                    TextField("Workspace name", text: $deleteName)
                    Button("Delete workspace", role: .destructive) {
                        act {
                            try await account.api.deleteWorkspace(ws.id, confirmName: deleteName)
                            await account.refresh()
                            app.route = .home
                        }
                    }
                    .disabled(deleteName != ws.name)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = ws.name; description = ws.description ?? "" }
        .task { rules = (try? await account.api.autoJoins(ws.id)) ?? [] }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.png, .jpeg, .gif, .webP]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            act {
                try await account.api.uploadLogo(workspaceId: ws.id, data: data, name: url.lastPathComponent, mimeType: MimeType.guess(forExtension: url.pathExtension))
                await account.refresh()
            }
        }
    }

    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { app.flash(error.localizedDescription) }
            rules = (try? await account.api.autoJoins(ws.id)) ?? rules
            await reload()
        }
    }
}

struct ClosedBoardsView: View {
    let account: Account
    @Environment(AppModel.self) private var app
    @State private var boards: [BoardSummary] = []
    @State private var confirm: ConfirmAction?

    var body: some View {
        List {
            if boards.isEmpty { Text("No closed boards.").foregroundStyle(.secondary) }
            ForEach(boards) { b in
                HStack {
                    BoardBackground(background: b.background).frame(width: 40, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading) {
                        Text(b.name)
                        Text(b.workspace?.name ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reopen") { act { try await account.api.updateBoard(b.id, .init(closed: false)) } }
                    Button("Delete") {
                        confirm = ConfirmAction(title: "Delete \(b.name)?", message: "All lists, cards and actions are deleted. There is no undo.", button: "Delete") {
                            act { try await account.api.deleteBoard(b.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Closed boards")
        .task { boards = (try? await account.api.closedBoards()) ?? [] }
        .confirm($confirm)
    }

    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { app.flash(error.localizedDescription) }
            boards = (try? await account.api.closedBoards()) ?? boards
            await account.refresh()
        }
    }
}

struct ProfileView: View {
    let account: Account
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var username = ""
    @State private var apps: [ConnectedApp] = []
    @State private var github: GitHubStatus?
    @State private var activity: [Activity] = []
    @State private var next: String?
    @State private var picking = false

    var body: some View {
        Form {
            Section("Profile") {
                HStack(spacing: 14) {
                    AvatarView(user: account.profile?.asUser, account: account, size: 64)
                    VStack(alignment: .leading) {
                        Text(account.profile?.email ?? "").foregroundStyle(.secondary)
                        HStack {
                            Button("Upload picture…") { picking = true }
                            if account.profile?.avatarKey != nil {
                                Button("Use Slack photo") { act { try await account.api.removeAvatar(userId: account.me ?? "") } }
                            }
                        }
                    }
                }
                TextField("Full name", text: $name)
                TextField("Username", text: $username, prompt: Text("2–32 lowercase letters, numbers or underscores"))
                Button("Save") {
                    act { try await account.api.updateProfile(name: name, username: .some(username.isEmpty ? nil : username)) }
                }
            }
            if let gh = github, gh.available {
                Section("GitHub") {
                    Text("Cards track GitHub issues you link to them and complete when the issue closes. Public issues work without this; connect your account to track issues in private repos you can see.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let c = gh.connection {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("@\(c.login)")
                                if let d = c.createdAt { Text("Connected \(d.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Disconnect") { act { try await account.api.disconnectGithub() } }
                        }
                    } else {
                        Button("Connect GitHub in Browser…") { NSWorkspace.shared.open(account.client.webURL("/me")) }
                        Text("Connecting signs you in to GitHub on the web. This page catches up when you come back.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Connected apps") {
                if apps.isEmpty { Text("No connected apps.").foregroundStyle(.secondary) }
                ForEach(apps) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.name)
                            if let d = a.lastActive { Text("Last active \(d.relative)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Revoke") { act { try await account.api.revokeApp(a.id) } }
                    }
                }
                Text("Revoking Hackban for Mac here signs this app out.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Your activity") {
                ForEach(activity) { a in ActivityRow(activity: a, account: account) }
                if next != nil { Button("Load more") { Task { await loadActivity(more: true) } } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(account.config.label) · Profile")
        .onAppear {
            name = account.profile?.name ?? ""
            username = account.profile?.username ?? ""
        }
        .task {
            apps = (try? await account.api.connectedApps()) ?? []
            github = try? await account.api.github()
            await loadActivity(more: false)
        }
        // Back from connecting GitHub in the browser: show it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { github = try? await account.api.github() }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.png, .jpeg, .gif, .webP]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let me = account.me else { return }
            act { try await account.api.uploadAvatar(userId: me, data: data, name: url.lastPathComponent, mimeType: MimeType.guess(forExtension: url.pathExtension)) }
        }
    }

    private func loadActivity(more: Bool) async {
        if let page = try? await account.api.myActivity(cursor: more ? next : nil) {
            activity = more ? activity + page.items : page.items
            next = page.next
        }
    }

    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { app.flash(error.localizedDescription) }
            await account.refresh()
            apps = (try? await account.api.connectedApps()) ?? apps
            github = try? await account.api.github()
        }
    }
}
