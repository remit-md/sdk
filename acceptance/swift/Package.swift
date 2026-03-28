// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "AcceptanceFlows",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),  // Root Package.swift exports RemitMd
    ],
    targets: [
        .executableTarget(
            name: "AcceptanceFlows",
            dependencies: [.product(name: "RemitMd", package: "sdk")],
            path: "Sources"
        ),
    ]
)
