// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkdownRenderer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MarkdownRenderer", targets: ["MarkdownRenderer"]),
        .executable(name: "markdown-render-cli", targets: ["markdown-render-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", branch: "gfm"),
        .package(url: "https://github.com/colinc86/MathJaxSwift", from: "3.4.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "MarkdownRenderer",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "MathJaxSwift", package: "MathJaxSwift"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(name: "markdown-render-cli", dependencies: ["MarkdownRenderer"]),
        .testTarget(
            name: "MarkdownRendererTests",
            dependencies: ["MarkdownRenderer"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
