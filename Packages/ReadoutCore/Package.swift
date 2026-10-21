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
        // swift-markdown's own cmark-gfm, for its C API (NestingCap).
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.7.0"),
    ],
    targets: [
        .target(
            name: "ReadoutCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .executableTarget(
            name: "readout-dump",
            dependencies: ["ReadoutCore"],
            path: "Tools/readout-dump"
        ),
        .executableTarget(
            name: "perf-probe",
            dependencies: ["ReadoutCore"],
            path: "Tools/perf-probe"
        ),
        .testTarget(
            name: "ReadoutCoreTests",
            dependencies: ["ReadoutCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
