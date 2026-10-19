// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Sotto", targets: ["Sotto"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "SottoCore"),
        .executableTarget(
            name: "Sotto",
            dependencies: ["SottoCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "SottoChecks", dependencies: ["SottoCore"], path: "Checks")
    ],
    swiftLanguageModes: [.v5]
)
