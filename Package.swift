// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "StreamingKit",
    platforms: [
        .iOS(.v10)
    ],
    products: [
        .library(
            name: "StreamingKit",
            targets: ["StreamingKit"]
        )        
    ],
    dependencies: [],
    targets: [
        .target(
            name: "StreamingKit",
            path: "StreamingKit/StreamingKit",
            publicHeadersPath: "SPMHeaderLinks",
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AudioToolbox")
            ]
        )
    ]
)
