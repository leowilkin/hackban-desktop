import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import CryptoKit
import Security
#endif

/// A build of the app on GitHub. CI publishes every build of `main` as a release tagged `build-<run number>`,
/// with the app zipped up as `Hackban.zip` and that zip's Ed25519 signature as `Hackban.zip.sig`; the run number is
/// also the app's `CFBundleVersion`.
public struct AppRelease: Decodable, Sendable, Equatable {
    public struct Asset: Decodable, Sendable, Equatable {
        public let name: String
        public let url: URL
        public let size: Int

        enum CodingKeys: String, CodingKey { case name, url = "browser_download_url", size }

        public init(name: String, url: URL, size: Int) {
            self.name = name; self.url = url; self.size = size
        }
    }

    public let tag: String
    public let name: String?
    public let notes: String?
    public let page: URL?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey { case tag = "tag_name", name, notes = "body", page = "html_url", assets }

    public init(tag: String, name: String? = nil, notes: String? = nil, page: URL? = nil, assets: [Asset] = []) {
        self.tag = tag; self.name = name; self.notes = notes; self.page = page; self.assets = assets
    }

    public static let archiveName = "Hackban.zip"
    public static let signatureName = archiveName + ".sig"

    /// N from a `build-N` tag; nil for any other tag.
    public var build: Int? {
        guard tag.hasPrefix("build-"), let n = Int(tag.dropFirst("build-".count)), n > 0 else { return nil }
        return n
    }

    /// The zipped app.
    public var archive: Asset? { assets.first { $0.name == Self.archiveName } }

    /// The archive's signature: 64 raw bytes of Ed25519 over the zip, made in CI with the update key.
    public var signature: Asset? { assets.first { $0.name == Self.signatureName } }

    /// A later build than `build`, with an app to install.
    public func isNewer(than build: Int) -> Bool {
        guard let mine = self.build, archive != nil else { return false }
        return mine > build
    }
}

public enum Updates {
    /// The newest release of `repo` ("owner/name"), or nil when it hasn't published one yet.
    public static func latest(repo: String, http: HTTP = URLSessionHTTP()) async throws -> AppRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw HackbanError.badURL(repo)
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await http.send(request)
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            // GitHub's errors are {"message": "..."}, e.g. when the hourly limit for signed-out requests runs out.
            struct Message: Decodable { let message: String? }
            let message = (try? JSONDecoder().decode(Message.self, from: data))?.message ?? ""
            throw HackbanError.http(status: response.statusCode, message: message.isEmpty ? "" : "GitHub: \(message)")
        }
        do {
            return try JSONDecoder().decode(AppRelease.self, from: data)
        } catch {
            throw HackbanError.decoding("\(error)")
        }
    }
}

#if os(macOS)
/// Puts a downloaded build in place of the running app.
public enum AppInstaller {
    public struct Failure: LocalizedError, Equatable {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Downloads the zipped app at `archive`, checks the zip is signed by `publicKey` (base64 of a raw Ed25519 key)
    /// with the signature at `signature`, that the app inside is `bundleIdentifier` at `build` with an intact code
    /// signature from the same signer as `app`, and swaps it in for `app`. Nothing changes if any step fails.
    ///
    /// The zip's signature is what ties a download to CI. Without a `publicKey` (a build with no
    /// `HackbanUpdatePublicKey`) the zip isn't checked. See `checkSameSigner` for the code signature.
    public static func install(from archive: URL, signature: URL?, publicKey: String?, build: Int, bundleIdentifier: String,
                               replacing app: URL, session: URLSession = .shared) async throws {
        // Before the app download, so an unsigned release fails straight away.
        var signed: (key: Curve25519.Signing.PublicKey, signature: Data)?
        if let publicKey {
            guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
                throw Failure("This build's update key (HackbanUpdatePublicKey) isn't valid.")
            }
            guard let signature else { throw Failure("The download isn't signed.") }
            let (data, response) = try await session.data(from: signature)
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                throw Failure("The signature download failed (\(status)).")
            }
            signed = (key, data)
        }

        let fm = FileManager.default
        // On the app's volume, so the swap is a rename.
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: dir) }

        let (download, response) = try await session.download(from: archive)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw Failure("The download failed (\(status)).")
        }
        let zip = dir.appendingPathComponent(archive.lastPathComponent)
        try fm.moveItem(at: download, to: zip)
        if let signed, !signed.key.isValidSignature(signed.signature, for: try Data(contentsOf: zip, options: .mappedIfSafe)) {
            throw Failure("The download isn't signed with Hackban's update key.")
        }
        do { try await run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) } catch {
            throw Failure("The download isn't a zipped app.")
        }

        let new = dir.appendingPathComponent(app.lastPathComponent)
        let info = Bundle(url: new)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier else { throw Failure("The download isn't this app.") }
        guard info?["CFBundleVersion"] as? String == String(build) else { throw Failure("The download isn't build \(build).") }
        do { try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path]) } catch {
            throw Failure("The download is damaged: its code signature doesn't check out.")
        }
        try checkSameSigner(new, as: app)
        _ = try fm.replaceItemAt(app, withItemAt: new)
    }

    /// When `app` is signed with a certificate, `new` has to meet its designated requirement, i.e. come from the same
    /// signer. An ad-hoc signed app has no certificate and its requirement is its own hash, which no other build can
    /// meet, so the check starts with the first certificate-signed build; the zip's signature covers the step there.
    static func checkSameSigner(_ new: URL, as app: URL) throws {
        var current: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &current) == errSecSuccess, let current,
              SecCodeCopySigningInformation(current, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else {
            throw Failure("Couldn't read this app's own code signature.")
        }
        let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        if certificates.isEmpty { return }

        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(new as CFURL, [], &candidate) == errSecSuccess, let candidate,
              SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
            throw Failure("The download isn't signed by the same certificate as this app.")
        }
    }

    static func run(_ tool: String, _ arguments: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { p in
                if p.terminationStatus == 0 { done.resume() } else {
                    done.resume(throwing: Failure("\(URL(fileURLWithPath: tool).lastPathComponent) exited with \(p.terminationStatus)."))
                }
            }
            do { try p.run() } catch { done.resume(throwing: error) }
        }
    }
}
#endif
