// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KadriCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "KadriCore", targets: ["KadriCore"]),
    ],
    targets: [
        .target(name: "KadriCore"),
        .testTarget(name: "KadriCoreTests", dependencies: ["KadriCore"]),
    ]
)
