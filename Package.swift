// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SimDeck", targets: ["SimDeck"])
    ],
    targets: [
        .target(
            name: "SimDeckCore",
            path: "Sources/SimDeckCore",
            resources: [.copy("Localization")]
        ),
        .executableTarget(
            name: "SimDeck",
            dependencies: ["SimDeckCore"],
            path: "Sources/SimDeck"
        ),
        .testTarget(
            name: "SimDeckCoreTests",
            dependencies: ["SimDeckCore"],
            path: "Tests/SimDeckCoreTests"
        )
    ]
)
