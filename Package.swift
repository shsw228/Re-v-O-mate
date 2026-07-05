// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RevOmate",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        // Core: HID transport + wire protocol + flash model.
        .target(
            name: "RevOmateKit"
        ),
        // A: connectivity spike CLI (version / probe / dump).
        .executableTarget(
            name: "revomate",
            dependencies: ["RevOmateKit"]
        ),
        // B: SwiftUI app skeleton.
        .executableTarget(
            name: "RevOmateApp",
            dependencies: ["RevOmateKit"]
        ),
    ]
)
