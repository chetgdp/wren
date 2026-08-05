// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wren",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "wren",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "wrenTests",
            dependencies: ["wren"]
        ),
    ]
)
