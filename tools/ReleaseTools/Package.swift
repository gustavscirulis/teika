// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReleaseTools", platforms: [.macOS(.v15)],
    products: [.executable(name: "teika-asc", targets: ["teika-asc"])],
    targets: [
        .target(name: "ReleaseCore"),
        .executableTarget(name: "teika-asc", dependencies: ["ReleaseCore"]),
        .testTarget(name: "ReleaseCoreTests", dependencies: ["ReleaseCore"])
    ], swiftLanguageModes: [.v5]
)
