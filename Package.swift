// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIPulse",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AIPulse",
            dependencies: [],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
