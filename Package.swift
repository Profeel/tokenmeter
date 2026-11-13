// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenMeter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TokenMeterCore", targets: ["TokenMeterCore"]),
        .executable(name: "tokenmeter", targets: ["tokenmeter-cli"]),
        .executable(name: "TokenMeterApp", targets: ["TokenMeterApp"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TokenMeterCore",
            dependencies: [],
            path: "Sources/TokenMeterCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "tokenmeter-cli",
            dependencies: ["TokenMeterCore"],
            path: "Sources/tokenmeter-cli"
        ),
        .executableTarget(
            name: "TokenMeterApp",
            dependencies: ["TokenMeterCore"],
            path: "Sources/TokenMeterApp"
        ),
        .testTarget(
            name: "TokenMeterCoreTests",
            dependencies: ["TokenMeterCore"],
            path: "Tests/TokenMeterCoreTests"
        )
    ]
)
