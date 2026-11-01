// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DevHub",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DevHubCore",
            path: "Sources/DevHubCore"
        ),
        .executableTarget(
            name: "DevHub",
            dependencies: ["DevHubCore"],
            path: "Sources/DevHub"
        ),
        .testTarget(
            name: "DevHubTests",
            dependencies: ["DevHubCore"],
            path: "Tests/DevHubTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
