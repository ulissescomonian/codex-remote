// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexRemote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexRemote", targets: ["CodexRemote"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexRemote",
            path: "Sources/CodexRemote"
        ),
        .testTarget(
            name: "CodexRemoteTests",
            dependencies: ["CodexRemote"],
            path: "Tests/CodexRemoteTests"
        ),
    ]
)

