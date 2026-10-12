// swift-tools-version: 6.0
import PackageDescription
import Foundation

let localPrefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".dependencies").path
let dependencyPrefix = ProcessInfo.processInfo.environment["MTP_DEPENDENCY_PREFIX"] ?? localPrefix

let package = Package(
    name: "AndroidMTP",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AndroidMTP", targets: ["AndroidMTP"])],
    targets: [
        .target(name: "MTPBridge", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I\(dependencyPrefix)/include"])],
                linkerSettings: [.unsafeFlags(["-L\(dependencyPrefix)/lib"]), .linkedLibrary("mtp")]),
        .target(name: "AndroidMTPCore", dependencies: ["MTPBridge"]),
        .executableTarget(name: "AndroidMTP", dependencies: ["AndroidMTPCore"]),
        .testTarget(name: "AndroidMTPCoreTests", dependencies: ["AndroidMTPCore"])
    ],
    swiftLanguageModes: [.v6]
)
