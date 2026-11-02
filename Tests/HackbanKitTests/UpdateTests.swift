import Foundation
import XCTest
@testable import HackbanKit

final class UpdateTests: XCTestCase {
    /// Trimmed from a real `GET /repos/{owner}/{repo}/releases/latest` response.
    let latest = #"""
    {
      "html_url": "https://github.com/example/hackban-desktop/releases/tag/build-42",
      "tag_name": "build-42",
      "name": "Build 42",
      "draft": false,
      "prerelease": false,
      "body": "fix: something",
      "assets": [
        {"name": "Hackban.zip", "size": 2048, "browser_download_url": "https://github.com/example/hackban-desktop/releases/download/build-42/Hackban.zip"},
        {"name": "notes.txt", "size": 10, "browser_download_url": "https://github.com/example/hackban-desktop/releases/download/build-42/notes.txt"}
      ]
    }
    """#

    func testDecodesRelease() throws {
        let r = try JSONDecoder().decode(AppRelease.self, from: Data(latest.utf8))
        XCTAssertEqual(r.build, 42)
        XCTAssertEqual(r.name, "Build 42")
        XCTAssertEqual(r.notes, "fix: something")
        XCTAssertEqual(r.archive?.size, 2048)
        XCTAssertEqual(r.archive?.url.lastPathComponent, "Hackban.zip")
    }

    func testBuildNumberOnlyFromBuildTags() {
        XCTAssertEqual(AppRelease(tag: "build-7").build, 7)
        XCTAssertNil(AppRelease(tag: "v1.0").build)
        XCTAssertNil(AppRelease(tag: "build-").build)
        XCTAssertNil(AppRelease(tag: "build-0").build)
        XCTAssertNil(AppRelease(tag: "build-12a").build)
    }

    func testNewerNeedsALaterBuildAndAnArchive() {
        let zip = AppRelease.Asset(name: "Hackban.zip", url: URL(string: "https://example.com/Hackban.zip")!, size: 1)
        XCTAssertTrue(AppRelease(tag: "build-5", assets: [zip]).isNewer(than: 4))
        XCTAssertTrue(AppRelease(tag: "build-5", assets: [zip]).isNewer(than: 0))  // a local build
        XCTAssertFalse(AppRelease(tag: "build-5", assets: [zip]).isNewer(than: 5))
        XCTAssertFalse(AppRelease(tag: "build-5", assets: [zip]).isNewer(than: 6))
        XCTAssertFalse(AppRelease(tag: "build-5").isNewer(than: 4))
        XCTAssertFalse(AppRelease(tag: "v2", assets: [zip]).isNewer(than: 4))
    }

    func testLatestAsksGitHub() async throws {
        let http = MockHTTP { _ in (200, self.latest) }
        let r = try await Updates.latest(repo: "example/hackban-desktop", http: http)
        XCTAssertEqual(r?.build, 42)
        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/repos/example/hackban-desktop/releases/latest")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testNoReleasesYetIsNil() async throws {
        let http = MockHTTP { _ in (404, #"{"message":"Not Found"}"#) }
        let r = try await Updates.latest(repo: "example/hackban-desktop", http: http)
        XCTAssertNil(r)
    }

    func testGitHubErrorsCarryTheirMessage() async {
        let http = MockHTTP { _ in (403, #"{"message":"API rate limit exceeded"}"#) }
        do {
            _ = try await Updates.latest(repo: "example/hackban-desktop", http: http)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? HackbanError, .http(status: 403, message: "GitHub: API rate limit exceeded"))
        }
    }
}

#if os(macOS)
final class InstallerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hackban-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A minimal ad-hoc-signed app in its own folder under `root`.
    func makeApp(_ folder: String, build: Int, id: String = "com.example.fake") async throws -> URL {
        let app = root.appendingPathComponent(folder).appendingPathComponent("Fake.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Fake"))
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleVersion": String(build), "CFBundleExecutable": "Fake", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try await AppInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    func zip(_ app: URL) async throws -> URL {
        let zip = app.deletingLastPathComponent().appendingPathComponent("Hackban.zip")
        try await AppInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        return zip
    }

    /// Read from disk: `Bundle` caches what it read at a path, which the swap doesn't invalidate.
    func build(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    }

    func testInstallsTheNewBuild() async throws {
        let installed = try await makeApp("installed", build: 1)
        let archive = try await zip(try await makeApp("release", build: 2))
        try await AppInstaller.install(from: archive, build: 2, bundleIdentifier: "com.example.fake", replacing: installed)
        XCTAssertEqual(build(of: installed), "2")
        try await AppInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed.path])
    }

    func testRefusesTheWrongBuild() async throws {
        let installed = try await makeApp("installed", build: 1)
        let archive = try await zip(try await makeApp("release", build: 2))
        await assertFails("The download isn't build 3.") {
            try await AppInstaller.install(from: archive, build: 3, bundleIdentifier: "com.example.fake", replacing: installed)
        }
        XCTAssertEqual(build(of: installed), "1")
    }

    func testRefusesAnotherApp() async throws {
        let installed = try await makeApp("installed", build: 1)
        let archive = try await zip(try await makeApp("release", build: 2, id: "com.example.other"))
        await assertFails("The download isn't this app.") {
            try await AppInstaller.install(from: archive, build: 2, bundleIdentifier: "com.example.fake", replacing: installed)
        }
        XCTAssertEqual(build(of: installed), "1")
    }

    func testRefusesATamperedApp() async throws {
        let installed = try await makeApp("installed", build: 1)
        let release = try await makeApp("release", build: 2)
        // Changed after signing.
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: release.appendingPathComponent("Contents/MacOS/Fake"))
        let archive = try await zip(release)
        await assertFails("The download is damaged: its code signature doesn't check out.") {
            try await AppInstaller.install(from: archive, build: 2, bundleIdentifier: "com.example.fake", replacing: installed)
        }
        XCTAssertEqual(build(of: installed), "1")
    }

    func assertFails(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \"\(message)\"", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
        }
    }
}
#endif
