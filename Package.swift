// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPaper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPaper", targets: ["MacPaper"]),
        .library(name: "MacPaperCore", targets: ["MacPaperCore"]),
    ],
    targets: [
        .target(name: "MacPaperCore"),
        .executableTarget(
            name: "MacPaper",
            dependencies: ["MacPaperCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("CoreImage"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(name: "MacPaperCoreTests", dependencies: ["MacPaperCore"]),
    ],
    swiftLanguageModes: [.v5]
)
