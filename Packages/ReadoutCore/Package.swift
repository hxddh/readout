// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReadoutCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReadoutCore", targets: ["ReadoutCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.0"),
    ],
    targets: [
        .target(
            name: "ReadoutCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .testTarget(
            name: "ReadoutCoreTests",
            dependencies: ["ReadoutCore"]
        ),
    ]
)
