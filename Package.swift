// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cpu-culprit",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CulpritCore"),
        .executableTarget(name: "culprit", dependencies: ["CulpritCore"]),
        .testTarget(name: "CulpritCoreTests", dependencies: ["CulpritCore"]),
    ],
    swiftLanguageModes: [.v5]
)
