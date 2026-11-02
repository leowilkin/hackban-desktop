import AppKit
import HackbanKit
import SwiftUI

/// How an account's sync is doing, in a few words and a symbol.
struct SyncSummary {
    let title: String
    let detail: String?
    let symbol: String
    let attention: Bool

    @MainActor
    init(_ account: Account) {
        let sync = account.sync
        let pending = sync.pendingCount
        let failed = sync.queue.failed.count
        let changes = pending == 1 ? "1 change" : "\(pending) changes"
        if sync.isOffline {
            let since = sync.offlineSince.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            title = "Offline\(since)"
            detail = pending > 0
                ? "Can't reach \(account.host). \(changes) saved on this Mac will sync when it's back."
                : "Can't reach \(account.host). You can keep working on boards you've opened before."
            symbol = "icloud.slash"
            attention = false
        } else if account.signedOut, pending > 0 {
            title = "Sign in to sync \(changes)"
            detail = nil
            symbol = "exclamationmark.icloud"
            attention = true
        } else if pending > 0 {
            title = sync.draining ? "Syncing \(changes)…" : "\(changes) waiting to sync"
            detail = nil
            symbol = "arrow.triangle.2.circlepath.icloud"
            attention = false
        } else if failed > 0 {
            title = failed == 1 ? "1 change couldn't sync" : "\(failed) changes couldn't sync"
            detail = nil
            symbol = "exclamationmark.icloud"
            attention = true
        } else if sync.queueSetAside != nil {
            title = "Some saved changes couldn't be read"
            detail = nil
            symbol = "exclamationmark.icloud"
            attention = true
        } else {
            title = "All changes synced"
            detail = nil
            symbol = "checkmark.icloud"
            attention = false
        }
    }
}

/// Toolbar button that shows while an account is offline or has changes waiting or failed.
struct SyncStatusButton: View {
    let account: Account
    @State private var showing = false

    var body: some View {
        if account.sync.hasStatus {
            let s = SyncSummary(account)
            Button { showing.toggle() } label: {
                Label(s.title, systemImage: s.symbol)
                    .foregroundStyle(s.attention ? Color.orange : Color.primary)
            }
            .help(s.title)
            .popover(isPresented: $showing, arrowEdge: .bottom) { SyncPanel(account: account) }
        }
    }
}

/// Sidebar footer line for an account with something to say about syncing.
struct SyncStatusRow: View {
    let account: Account
    @Environment(AppModel.self) private var app
    @State private var showing = false

    var body: some View {
        let s = SyncSummary(account)
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                if account.sync.draining {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: s.symbol).foregroundStyle(s.attention ? Color.orange : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.title).lineLimit(1)
                    if app.accounts.count > 1 { Text(account.config.label).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.detail ?? s.title)
        .popover(isPresented: $showing, arrowEdge: .trailing) { SyncPanel(account: account) }
    }
}

/// What's waiting, what failed and why, and conflicts to settle.
struct SyncPanel: View {
    let account: Account

    private var sync: SyncEngine { account.sync }

    var body: some View {
        let s = SyncSummary(account)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: s.symbol)
                    .font(.title2)
                    .foregroundStyle(s.attention ? Color.orange : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.headline)
                    if let d = s.detail { Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                if sync.isOffline {
                    Button("Try Now") { sync.probeNow() }.controlSize(.small)
                }
            }

            if let url = sync.queueSetAside {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Changes saved by another version of Hackban couldn't be read, so they weren't sent. They're kept in a file you can look at.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Dismiss") { sync.dismissSetAside() }
                    }
                    .controlSize(.small)
                }
            }

            let conflicts = sync.queue.failed.filter(\.isConflict)
            let failures = sync.queue.failed.filter { !$0.isConflict }
            if !sync.queue.pending.isEmpty || !sync.queue.failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !conflicts.isEmpty {
                            section("Edited by someone else too") {
                                ForEach(conflicts) { f in ConflictRow(sync: sync, failed: f) }
                            }
                        }
                        if !failures.isEmpty {
                            section("Couldn't sync") {
                                ForEach(failures) { f in FailureRow(sync: sync, failed: f) }
                            }
                        }
                        if !sync.queue.pending.isEmpty {
                            section("Waiting to sync") {
                                ForEach(sync.queue.pending) { op in
                                    Label(sync.describe(op), systemImage: op.id == sync.queue.sending ? "arrow.up.circle" : "clock")
                                        .font(.callout)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct FailureRow: View {
    let sync: SyncEngine
    let failed: FailedOp

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sync.describe(failed.op)).font(.callout)
            Text(failed.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Try Again") { sync.retry(failed.id) }
                Button("Discard") { sync.discard(failed.id) }
            }
            .controlSize(.small)
        }
    }
}

private struct ConflictRow: View {
    let sync: SyncEngine
    let failed: FailedOp

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sync.describe(failed.op)).font(.callout)
            ForEach(failed.conflicts ?? [], id: \.field) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.field == "title" ? "Title" : "Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    version("Theirs", c.theirs)
                    version("Yours", c.mine)
                }
            }
            HStack {
                Button("Keep Theirs") { sync.discard(failed.id) }
                Button("Use Mine") { sync.retry(failed.id, useMine: true) }
                Button("Copy Mine") { copyToPasteboard((failed.conflicts ?? []).map(\.mine).joined(separator: "\n\n")) }
                    .help("Copy your version, to merge by hand")
            }
            .controlSize(.small)
        }
    }

    private func version(_ who: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(who).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Text(text.isEmpty ? "(empty)" : text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }
}
