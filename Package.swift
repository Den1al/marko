// swift-tools-version: 6.2
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Marko",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "MarkoCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .target(
            name: "MarkoEditor",
            dependencies: ["MarkoCore"],
            swiftSettings: mainActorByDefault
        ),
        // What the command-line tool and the app agree on. Foundation only: the tool must start fast.
        .target(name: "MarkoCommand"),
        .executableTarget(name: "MarkoCLI", dependencies: ["MarkoCommand"]),
        .executableTarget(
            name: "MarkoApp",
            dependencies: ["MarkoEditor", "MarkoCommand"],
            swiftSettings: mainActorByDefault
        ),
        // Owns Tests/Fixtures so both test targets share one copied resource directory.
        .target(
            name: "FixtureSupport",
            path: "Tests",
            exclude: ["MarkoCoreTests", "MarkoEditorTests", "MarkoCommandTests"],
            sources: ["FixtureSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MarkoCoreTests",
            dependencies: [
                "MarkoCore",
                "FixtureSupport",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(name: "MarkoCommandTests", dependencies: ["MarkoCommand"]),
        .testTarget(
            name: "MarkoEditorTests",
            dependencies: ["MarkoApp", "MarkoEditor", "MarkoCommand", "FixtureSupport"],
            swiftSettings: mainActorByDefault
        ),
    ]
)
