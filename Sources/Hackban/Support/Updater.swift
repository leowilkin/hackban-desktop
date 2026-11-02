import AppKit
import Foundation
import HackbanKit
import Observation

/// Installs newer builds from GitHub, where CI publishes every build of `main` as a release.
///
/// Released builds check shortly after launch and every six hours while automatic updates are on. Local builds
/// (build 0) only check when asked, and then offer the latest release.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()
    static let automaticKey = "hackban:autoUpdate"
    /// The build the user said "Later" to, so background checks don't ask about it again.
    private static let skippedKey = "hackban:skippedBuild"

    /// A newer release than this build, once a check has found one.
    private(set) var available: AppRelease?
    private(set) var busy = false
    /// Found by a background check while the app wasn't active; offered when it next is.
    private var pending: AppRelease?
    private var loop: Task<Void, Never>?

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// This build's number (`CFBundleVersion`); 0 for a local build.
    let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    private let repo = Bundle.main.object(forInfoDictionaryKey: "HackbanUpdateRepo") as? String

    var versionDescription: String { build > 0 ? "\(version) (build \(build))" : "\(version) (local build)" }

    func start() {
        guard loop == nil else { return }
        loop = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            while !Task.isCancelled {
                if build > 0, UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true {
                    await check(userInitiated: false)
                }
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        guard let repo else {
            if userInitiated { inform("Updates aren't set up for this build.", "Its Info.plist has no HackbanUpdateRepo.") }
            return
        }
        busy = true
        let result: Result<AppRelease?, Error>
        do { result = .success(try await Updates.latest(repo: repo)) } catch { result = .failure(error) }
        busy = false

        switch result {
        case .failure(let error):
            if userInitiated { inform("Couldn't check for updates.", error.localizedDescription) }
        case .success(let release):
            guard let release, let n = release.build, release.isNewer(than: build) else {
                available = nil
                if userInitiated {
                    inform("You're up to date.", release == nil ? "No builds have been published yet." : "Hackban \(versionDescription) is the newest build.")
                }
                return
            }
            available = release
            if userInitiated {
                offer(release)
            } else if UserDefaults.standard.integer(forKey: Self.skippedKey) != n {
                if NSApp.isActive { offer(release) } else { pending = release }
            }
        }
    }

    /// Offers an update a background check found while the app was in the background.
    func appDidBecomeActive() {
        guard let release = pending else { return }
        pending = nil
        offer(release)
    }

    private func offer(_ release: AppRelease) {
        guard let n = release.build else { return }
        let alert = NSAlert()
        alert.messageText = "Hackban build \(n) is available"
        var info = build > 0 ? "You have build \(build)." : "You're on a local build."
        if let notes = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            info += "\n\n" + (notes.count > 600 ? String(notes.prefix(600)) + "…" : notes)
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await install(release) }
        } else {
            UserDefaults.standard.set(n, forKey: Self.skippedKey)
        }
    }

    /// Downloads the release, checks it's this app at that build and intact, swaps it in for the running copy and
    /// relaunches.
    func install(_ release: AppRelease) async {
        guard !busy, let n = release.build, let asset = release.archive, let id = Bundle.main.bundleIdentifier else { return }
        let app = Bundle.main.bundleURL
        // A quarantined app opened from Downloads runs from a read-only, randomised copy ("App Translocation").
        if app.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            inform("Move Hackban to Applications to update it.", "macOS won't let Hackban replace itself where it is now. Drag it into the Applications folder, open it from there and check again.")
            return
        }
        busy = true
        defer { busy = false }
        AppModel.shared.flash("Downloading build \(n)…")
        do {
            try await AppInstaller.install(from: asset.url, build: n, bundleIdentifier: id, replacing: app)
            try relaunch(app)
        } catch {
            inform("Couldn't install build \(n).", error.localizedDescription)
        }
    }

    /// Waits for this process to exit, then opens the (now updated) app again.
    private func relaunch(_ app: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try p.run()
        NSApp.terminate(nil)
    }

    private func inform(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
