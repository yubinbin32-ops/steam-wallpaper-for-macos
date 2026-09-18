// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallpaper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WallpaperCore",
            targets: ["WallpaperCore"]
        ),
        .executable(
            name: "WallpaperApp",
            targets: ["WallpaperApp"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WallpaperCore",
            dependencies: []
        ),
        .executableTarget(
            name: "WallpaperApp",
            dependencies: ["WallpaperCore"]
        ),
        .testTarget(
            name: "WallpaperTests",
            dependencies: ["WallpaperCore"]
        )
    ]
)
