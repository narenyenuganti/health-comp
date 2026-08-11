// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CompetitionCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CompetitionCore", targets: ["CompetitionCore"]),
    ],
    targets: [
        .target(name: "CompetitionCore"),
        .testTarget(
            name: "CompetitionCoreTests",
            dependencies: ["CompetitionCore"]
        ),
    ]
)
