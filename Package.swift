// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Postie",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PostieCore", targets: ["PostieCore"]),
        .executable(name: "Postie", targets: ["PostieApp"]),
        .executable(name: "PostieHTTPFixture", targets: ["PostieHTTPFixture"]),
    ],
    targets: [
        .target(name: "PostieCore"),
        .executableTarget(name: "PostieApp", dependencies: ["PostieCore"]),
        .executableTarget(name: "PostieHTTPFixture"),
        .testTarget(name: "PostieCoreTests", dependencies: ["PostieCore", "PostieHTTPFixture"]),
        .testTarget(name: "PostieAppTests", dependencies: ["PostieApp", "PostieCore", "PostieHTTPFixture"]),
    ]
)
