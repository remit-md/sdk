// swift-tools-version: 5.7
import PackageDescription

// Root-level Package.swift for Swift Package Manager consumers.
// SPM resolves packages from the repo root, so this file points
// into swift/Sources and swift/Tests for the actual implementation.

let package = Package(
    name: "RemitMd",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "RemitMd", targets: ["RemitMd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/GigaBitcoin/secp256k1.swift.git", "0.16.0"..<"0.20.0"),
    ],
    targets: [
        .target(
            name: "RemitMd",
            dependencies: [
                .product(name: "secp256k1", package: "secp256k1.swift"),
            ],
            path: "swift/Sources/RemitMd"
        ),
        .testTarget(
            name: "RemitMdTests",
            dependencies: ["RemitMd"],
            path: "swift/Tests/RemitMdTests"
        ),
    ]
)
