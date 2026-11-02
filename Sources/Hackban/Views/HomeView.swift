import HackbanKit
import SwiftUI

/// Every account's boards on one page: recent, starred, then each workspace.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var creatingBoard: Account?

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)]

    var body: some View {
        let boards = app.visibleAccounts.reduce(0) { $0 + $1.allBoards.count }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageTitle(title: "Home", detail: "\(boards) \(boards == 1 ? "board" : "boards")", icon: "square.grid.2x2")
                ForEach(app.visibleAccounts) { a in
                    VStack(alignment: .leading, spacing: 18) {
                        if app.visibleAccounts.count > 1 {
                            HStack {
                                Circle().fill(a.color).frame(width: 8, height: 8)
                                Text(a.config.label).font(.headline)
                                Text(a.host).foregroundStyle(.secondary)
                            }
                        }
                        if a.signedOut {
                            Button("Signed out of \(a.host). Sign in again…") { Task { await app.reauthenticate(a) } }
                        }
                        if let e = a.lastError, !a.signedOut { Text(e).foregroundStyle(.red).font(.callout) }
                        if !a.starredBoards.isEmpty { section("Starred boards", systemImage: "star", a.starredBoards, a) }
                        if !a.recent.isEmpty { section("Recently viewed", systemImage: "clock", a.recent, a) }
                        ForEach(a.workspaces) { w in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    WorkspaceLogo(name: w.name, logo: w.logo, account: a, size: 18)
                                    Text(w.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Boards") { app.route = .workspace(account: a.id, id: w.id) }.buttonStyle(.link)
                                }
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                    ForEach(w.boards) { b in BoardTile(board: b, account: a) }
                                    Button { creatingBoard = a } label: {
                                        Label("New board", systemImage: "plus")
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, minHeight: 90)
                                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                            .contentShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if !a.guestBoards.isEmpty { section("Guest boards", systemImage: "person.2", a.guestBoards, a) }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Home")
        .hidingToolbarTitle()
        .toolbar {
            ToolbarItem {
                Button { Task { await app.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
        }
        .sheet(item: $creatingBoard) { a in CreateBoardView(account: a).environment(app) }
    }

    private func section(_ title: String, systemImage: String, _ boards: [BoardSummary], _ a: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(boards) { b in BoardTile(board: b, account: a) }
            }
        }
    }
}

struct BoardTile: View {
    let board: BoardSummary
    let account: Account
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Button { app.open(board: board.id, in: account) } label: {
            ZStack(alignment: .topLeading) {
                BoardBackground(background: board.background, bgImage: board.bgImage, account: account)
                Color.black.opacity(hovering ? 0.25 : 0.12)
                Text(board.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(10)
                    .lineLimit(2)
                if hovering || board.starred == true {
                    Image(systemName: board.starred == true ? "star.fill" : "star")
                        .foregroundStyle(board.starred == true ? .yellow : .white)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .onTapGesture {
                            app.run(account) {
                                try await account.api.starBoard(board.id, !(board.starred ?? false))
                                await account.refresh()
                            }
                        }
                }
            }
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct CreateBoardView: View {
    let account: Account
    var workspaceId: String? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var workspace = ""
    @State private var background = Palette.boardColors[0]
    @State private var visibility = "workspace"
    @State private var template = "basic"
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create board").font(.title2.bold())
            BoardBackground(background: background).frame(height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) { Text(name.isEmpty ? "Board title" : name).font(.headline).foregroundStyle(.white).padding(10) }
            BackgroundPicker(selection: $background)
            Form {
                TextField("Title", text: $name)
                Picker("Workspace", selection: $workspace) {
                    ForEach(account.workspaces) { w in Text(w.name).tag(w.id) }
                }
                Picker("Visibility", selection: $visibility) {
                    Text("Private").tag("private")
                    Text("Workspace").tag("workspace")
                    Text("Public").tag("public")
                }
                Picker("Start with", selection: $template) {
                    Text("To Do, Doing, Done").tag("basic")
                    Text("No lists").tag("empty")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || workspace.isEmpty || busy)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { workspace = workspaceId ?? account.workspaces.first?.id ?? "" }
    }

    private func create() {
        busy = true
        Task {
            do {
                let b = try await account.api.createBoard(name: name.trimmingCharacters(in: .whitespaces), workspaceId: workspace, background: background, visibility: visibility, template: template)
                await account.refresh()
                app.open(board: b.id, in: account)
                dismiss()
            } catch {
                app.flash(error.localizedDescription)
            }
            busy = false
        }
    }
}

struct BackgroundPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            grid(Palette.boardGradients)
            grid(Palette.boardColors)
        }
    }

    /// Six to a row, sized to the space given: a row of nine colours overflowed the board inspector.
    private func grid(_ backgrounds: [String]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(backgrounds, id: \.self) { swatch($0) }
        }
    }

    private func swatch(_ bg: String) -> some View {
        BoardBackground(background: bg)
            .frame(height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay { if selection == bg { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
            .onTapGesture { selection = bg }
    }
}

struct CreateWorkspaceView: View {
    let account: Account
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create workspace").font(.title2.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        do {
                            let w = try await account.api.createWorkspace(name: name)
                            await account.refresh()
                            app.route = .workspace(account: account.id, id: w.id)
                            dismiss()
                        } catch { app.flash(error.localizedDescription) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}
