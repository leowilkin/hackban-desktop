#!/usr/bin/env swift
// The Ed25519 key that releases are signed with, so the updater only installs builds from this repo's CI.
// (Hackban.app is ad-hoc signed, which says it arrived intact but not who built it.)
//
//   ./Scripts/update-key.swift new <file>
//       Makes a key pair. Writes the private key (base64) to <file>, readable only by you, for the
//       HACKBAN_UPDATE_KEY secret, and prints the public key for HackbanUpdatePublicKey in Resources/Info.plist.
//   ./Scripts/update-key.swift sign <zip> <public key>
//       Signs <zip> with the private key in $HACKBAN_UPDATE_KEY and writes the 64-byte signature to <zip>.sig,
//       after checking the key matches <public key>, so a release never goes out signed with a key the app refuses.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-key: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("new", 2):
    let key = Curve25519.Signing.PrivateKey()
    // Created 0600 and never over an existing file, so it can't clobber a key or be readable for a moment.
    let fd = open(args[1], O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { fail("couldn't create \(args[1]): \(String(cString: strerror(errno)))") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do { try file.write(contentsOf: Data(key.rawRepresentation.base64EncodedString().utf8)) } catch {
        fail("couldn't write \(args[1]): \(error.localizedDescription)")
    }
    FileHandle.standardError.write(Data("Wrote the private key to \(args[1]). Public key, for HackbanUpdatePublicKey:\n".utf8))
    print(key.publicKey.rawRepresentation.base64EncodedString())

case ("sign", 3):
    // Never echoed, so it stays out of CI logs.
    let secret = ProcessInfo.processInfo.environment["HACKBAN_UPDATE_KEY"] ?? ""
    if secret.isEmpty { fail("HACKBAN_UPDATE_KEY isn't set") }
    guard let raw = Data(base64Encoded: secret.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("HACKBAN_UPDATE_KEY isn't a base64 Ed25519 private key")
    }
    guard Data(base64Encoded: args[2]) == key.publicKey.rawRepresentation else {
        fail("HACKBAN_UPDATE_KEY isn't the private half of \(args[2]), so the app would refuse this release")
    }
    let zip = URL(fileURLWithPath: args[1])
    do {
        try key.signature(for: Data(contentsOf: zip)).write(to: zip.appendingPathExtension("sig"))
    } catch {
        fail("couldn't sign \(args[1]): \(error.localizedDescription)")
    }
    print("Signed \(args[1]) into \(args[1]).sig")

default:
    fail("usage: update-key.swift new <file> | update-key.swift sign <zip> <public key>")
}
