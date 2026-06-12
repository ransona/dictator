// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictatorMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Dictator", targets: ["Dictator"])
    ],
    targets: [
        .executableTarget(
            name: "Dictator",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security")
            ]
        )
    ]
)
