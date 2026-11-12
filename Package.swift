// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MSnip",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "MSnipCore", targets: ["MSnipCore"]),
        .executable(name: "MSnip", targets: ["MSnip"])
    ],
    targets: [
        .target(
            name: "MSnipCore",
            path: "Sources/MSnipCore"
        ),
        .executableTarget(
            name: "MSnip",
            dependencies: ["MSnipCore"],
            path: "Sources/MSnip",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "MSnipTests",
            dependencies: ["MSnipCore"],
            path: "Sources/MSnipTests"
        )
    ]
)
