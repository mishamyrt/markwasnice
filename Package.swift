// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Markwasnice",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Markwasnice", targets: ["Markwasnice"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")
    ],
    targets: [
        .executableTarget(
            name: "Markwasnice",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            resources: [
                .copy("../../Assets/Fonts")
            ]
        ),
        .testTarget(
            name: "MarkwasniceTests",
            dependencies: [
                "Markwasnice",
                .product(name: "Markdown", package: "swift-markdown")
            ]
        )
    ]
)
