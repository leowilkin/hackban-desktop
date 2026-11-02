import HackbanKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.accounts.isEmpty {
                WelcomeView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                } detail: {
                    DetailView(route: app.route ?? .home)
                }
            }
        }
        .overlay { ToastOverlay() }
        .sheet(item: $app.openCard) { ref in
            if let a = app.account(ref.account) {
                CardSheet(model: CardModel(app: app, account: a, cardId: ref.cardId))
                    .environment(app)
            }
        }
        .sheet(isPresented: $app.addingAccount) { AddAccountView().environment(app) }
    }
}

struct DetailView: View {
    let route: Route
    @Environment(AppModel.self) private var app

    var body: some View {
        switch route {
        case .home: HomeView()
        case .myCards: MyCardsView()
        case .notifications: NotificationsView()
        case .board(let acc, let id):
            if let a = app.account(acc) { BoardScreen(model: app.boardModel(account: a, boardId: id)).id("\(acc)|\(id)") } else { missing }
        case .workspace(let acc, let id):
            if let a = app.account(acc) { WorkspaceView(account: a, workspaceId: id).id("\(acc)|\(id)") } else { missing }
        case .profile(let acc):
            if let a = app.account(acc) { ProfileView(account: a).id(acc) } else { missing }
        case .closedBoards(let acc):
            if let a = app.account(acc) { ClosedBoardsView(account: a).id(acc) } else { missing }
        }
    }

    private var missing: some View {
        ContentUnavailableView("That account was removed", systemImage: "person.crop.circle.badge.xmark")
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            HackbanMark(size: 64)
            Text("Hackban").font(.largeTitle.bold())
            Text("Sign in to a Hackban server to get started. You can add more later, like a work server and a personal one, and see all of them at once.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Add a Hackban server…") { app.addingAccount = true }
                .buttonStyle(.borderedProminent)
                .tint(.hackClubRed)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AddAccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var server = "hackban.hackclub.com"
    @State private var label = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Hackban server").font(.title2.bold())
            Text("You'll sign in in your browser and approve Hackban for Mac. The server has to support native app sign-in.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Server", text: $server, prompt: Text("hackban.hackclub.com"))
                TextField("Name", text: $label, prompt: Text("e.g. Work, Personal"))
            }
            if let e = app.signInError {
                Text(e).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    busy = true
                    Task {
                        await app.addAccount(server: server, label: label)
                        busy = false
                    }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Sign In") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || server.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { app.signInError = nil }
    }
}
