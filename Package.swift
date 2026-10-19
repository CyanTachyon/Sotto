// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Sotto", targets: ["Sotto"])],
    targets: [
        .target(name: "SottoCore"),
        .executableTarget(name: "Sotto", dependencies: ["SottoCore"]),
        .executableTarget(name: "SottoChecks", dependencies: ["SottoCore"], path: "Checks")
    ],
    swiftLanguageModes: [.v5]
)
