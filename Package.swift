// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AVDMenuBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AVDMenuBar", targets: ["AVDMenuBar"])
    ],
    targets: [
        .target(
            name: "AVDCore",
            path: "Sources/AVDCore",
            resources: [.copy("Localization")]
        ),
        .executableTarget(
            name: "AVDMenuBar",
            dependencies: ["AVDCore"],
            path: "Sources/AVDMenuBar"
        ),
        .testTarget(
            name: "AVDCoreTests",
            dependencies: ["AVDCore"],
            path: "Tests/AVDCoreTests"
        )
    ]
)
