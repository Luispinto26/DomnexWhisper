// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DomnexWhisper",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "DomnexWhisper",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/DomnexWhisper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
