// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "wren",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.3.0"
        ),
        .package(
            url: "https://github.com/SimplyDanny/SwiftLintPlugins",
            from: "0.65.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "wren",
            dependencies: [
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser"
                ),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            plugins: [
                .plugin(
                    name: "SwiftLintBuildToolPlugin",
                    package: "SwiftLintPlugins"
                ),
            ]
        ),
        .testTarget(
            name: "wrenTests",
            dependencies: ["wren"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
