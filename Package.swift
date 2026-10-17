// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatFloat",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ChatFloat", targets: ["ChatFloat"])],
    targets: [
        .target(name: "ChatCore"),
        .executableTarget(name: "ChatFloat", dependencies: ["ChatCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["ChatCore"], path: "Checks")
    ],
    swiftLanguageModes: [.v5]
)
