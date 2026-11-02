// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftMCPServer",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    products: [
        .executable(
            name: "swift-mcp-server",
            targets: ["SwiftMCPServer"]
        ),
        .library(
            name: "SwiftMCPCore",
            targets: ["SwiftMCPCore"]
        ),
        .library(
            name: "SourceKitLSP",
            targets: ["SourceKitLSP"]
        ),
        .library(
            name: "APIAvailability",
            targets: ["APIAvailability"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.85.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftMCPServer",
            dependencies: [
                "SwiftMCPCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "SourceKitLSP",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "APIAvailability"
        ),
        .target(
            name: "SwiftMCPCore",
            dependencies: [
                "SourceKitLSP",
                "APIAvailability",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "SwiftMCPServerTests",
            dependencies: ["SwiftMCPCore", "SourceKitLSP", "APIAvailability"]
        ),
    ]
)
