// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sightglass",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SightglassCore", linkerSettings: [.linkedLibrary("IOReport")]),
        .executableTarget(name: "sightglass-probe", dependencies: ["SightglassCore"]),
        .executableTarget(name: "Sightglass", dependencies: ["SightglassCore"]),
        .testTarget(name: "SightglassCoreTests", dependencies: ["SightglassCore"]),
    ],
    swiftLanguageModes: [.v5]
)
