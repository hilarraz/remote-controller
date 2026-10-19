// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleTVKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppleTVKit", targets: ["AppleTVKit"]),
        .executable(name: "atvctl", targets: ["atvctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.4.0"),
    ],
    targets: [
        .target(
            name: "AppleTVKit",
            dependencies: [.product(name: "BigInt", package: "BigInt")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "atvctl",
            dependencies: ["AppleTVKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AppleTVKitTests",
            dependencies: ["AppleTVKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
