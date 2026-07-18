// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Markwasnice",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Markwasnice", targets: ["Markwasnice"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        .package(url: "https://github.com/mishamyrt/swift-typograf.git", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Markwasnice",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Typograf", package: "swift-typograf"),
            ],
            resources: [
                .copy("../../Assets/Fonts"),
                .copy("../../Assets/text.line.middle.and.arrowtriangle.svg"),
            ]
        ),
        .testTarget(
            name: "MarkwasniceTests",
            dependencies: [
                "Markwasnice",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
    ]
)
