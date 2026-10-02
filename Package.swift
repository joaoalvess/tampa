// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tampa",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "VirtualDisplayPrivate"),
        .executableTarget(name: "Tampa", dependencies: ["VirtualDisplayPrivate"])
    ]
)
