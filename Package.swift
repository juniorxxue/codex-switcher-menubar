// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "codex-switcher-menubar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "CodexSwitcherMenubar",
            targets: ["CodexSwitcherMenubar"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.9.0")
    ],
    targets: [
        .executableTarget(
            name: "CodexSwitcherMenubar",
            dependencies: [
                .product(name: "CryptoSwift", package: "CryptoSwift")
            ]
        ),
        .testTarget(
            name: "CodexSwitcherMenubarTests",
            dependencies: [
                "CodexSwitcherMenubar",
                .product(name: "CryptoSwift", package: "CryptoSwift")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
