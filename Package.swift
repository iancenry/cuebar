// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cuebar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cuebar", targets: ["Cuebar"]),
        .library(name: "PromptCore", targets: ["PromptCore"]),
    ],
    targets: [
        .target(
            name: "PromptCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Cuebar",
            dependencies: ["PromptCore"],
            exclude: ["Info.plist", "Cuebar.entitlements"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PromptCoreTests",
            dependencies: ["PromptCore"]
        ),
    ]
)
