// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "je",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "JECore", targets: ["JECore"]),
        .executable(name: "je", targets: ["je"])
    ],
    targets: [
        .target(name: "JECore"),
        .executableTarget(name: "je", dependencies: ["JECore"]),
        .testTarget(name: "JECoreTests", dependencies: ["JECore"])
    ]
)
