// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIWallpaper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIWallpaper",
            path: "Sources/AIWallpaper",
            resources: [.copy("Resources/Segmentation.mlpackage")]
        )
    ]
)
