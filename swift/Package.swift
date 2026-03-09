// swift-tools-version: 5.7
import PackageDescription

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
        // secp256k1 ECDSA signing — lightweight C wrapper, no other dependencies
        .package(url: "https://github.com/GigaBitcoin/secp256k1.swift.git", "0.16.0"..<"0.20.0"),
    ],
    targets: [
        .target(
            name: "RemitMd",
            dependencies: [
                .product(name: "secp256k1", package: "secp256k1.swift"),
            ]
        ),
        .testTarget(
            name: "RemitMdTests",
            dependencies: ["RemitMd"]
        ),
    ]
)
