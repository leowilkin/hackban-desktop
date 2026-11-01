// swift-tools-version:5.9
import PackageDescription

// HackbanKit is Foundation-only, so it builds and tests on Linux too (CI, containers).
// The SwiftUI app target only exists on macOS.
var targets: [Target] = [
    .target(name: "HackbanKit", path: "Sources/HackbanKit"),
    .testTarget(name: "HackbanKitTests", dependencies: ["HackbanKit"], path: "Tests/HackbanKitTests"),
]
var products: [Product] = [.library(name: "HackbanKit", targets: ["HackbanKit"])]

#if os(macOS)
targets.append(.executableTarget(name: "Hackban", dependencies: ["HackbanKit"], path: "Sources/Hackban"))
products.append(.executable(name: "Hackban", targets: ["Hackban"]))
#endif

let package = Package(
    name: "Hackban",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
