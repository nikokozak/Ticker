// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ticker",
    platforms: [
        .macOS(.v14)  // Required for MLX Swift
    ],
    products: [
        .executable(name: "Ticker", targets: ["Ticker"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "Ticker",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
