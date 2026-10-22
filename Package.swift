// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Postie",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PostieCore", targets: ["PostieCore"]),
        .library(name: "PostieAutomation", targets: ["PostieAutomation"]),
        .executable(name: "PostieCLI", targets: ["PostieCLI"]),
        .executable(name: "Postie", targets: ["PostieApp"]),
        .executable(name: "PostieHTTPFixture", targets: ["PostieHTTPFixture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
    ],
    targets: [
        .target(name: "PostieCore"),
        .target(name: "PostieAutomation", dependencies: ["PostieCore"]),
        .target(
            name: "PostieControl",
            dependencies: [
                "PostieAutomation", .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]),
        .executableTarget(
            name: "PostieApp",
            dependencies: [
                "PostieCore",
                "PostieAutomation",
                "PostieControl",
            ]
        ),
        .executableTarget(name: "PostieHTTPFixture"),
        .executableTarget(name: "PostieCLI", dependencies: ["PostieAutomation", "PostieControl"]),
        .testTarget(name: "PostieCoreTests", dependencies: ["PostieCore", "PostieHTTPFixture"]),
        .testTarget(name: "PostieAutomationTests", dependencies: ["PostieAutomation", "PostieCore"]),
        .testTarget(name: "PostieControlTests", dependencies: ["PostieControl", "PostieAutomation"]),
        .testTarget(
            name: "PostieAppTests",
            dependencies: ["PostieApp", "PostieCore", "PostieAutomation", "PostieControl", "PostieHTTPFixture"]),
    ]
)
