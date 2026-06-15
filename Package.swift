// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Phorganize",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Phorganize", targets: ["PhorganizeApp"]),
        .library(name: "PhorganizeCore", targets: ["PhorganizeCore"])
    ],
    targets: [
        .target(
            name: "PhorganizeCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ImageIO")
            ]
        ),
        .executableTarget(
            name: "PhorganizeApp",
            dependencies: ["PhorganizeCore"],
            exclude: ["Info.plist", "Phorganize.entitlements", "PrivacyInfo.xcprivacy"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "PhorganizeCoreTests",
            dependencies: ["PhorganizeCore"]
        )
    ]
)
