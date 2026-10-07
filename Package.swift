// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AltairSim",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AltairCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "AltairSim",
            dependencies: ["AltairCore"],
            exclude: ["Resources/README.md"],
            resources: [.copy("Resources/roms"), .copy("Resources/disks"), .copy("Resources/cpu_tests")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AltairCoreTests",
            dependencies: ["AltairCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
