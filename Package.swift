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
            path: "Sources/MSnipCore",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "MSnip",
            dependencies: ["MSnipCore"],
            path: "Sources/MSnip",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Vision"),
                .linkedFramework("VisionKit"),
                .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(
            name: "MSnipTests",
            dependencies: ["MSnipCore"],
            path: "Sources/MSnipTests"
        )
    ]
)
