// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CleanMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CleanMac", targets: ["CleanMac"])],
    targets: [
        .target(name: "CleanMacCore"),
        .executableTarget(name: "CleanMac", dependencies: ["CleanMacCore"]),
        .testTarget(name: "CleanMacCoreTests", dependencies: ["CleanMacCore"]),
        .testTarget(name: "CleanMacAppTests", dependencies: ["CleanMac", "CleanMacCore"]),
    ]
)
