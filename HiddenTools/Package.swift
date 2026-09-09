// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HiddenTools",
    platforms: [
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "HiddenTools",
            path: "Sources/HiddenTools"
        )
    ]
)
