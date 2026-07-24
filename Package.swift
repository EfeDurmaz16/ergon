// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Ergon",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Ergon", targets: ["Ergon"]),
        .library(name: "ErgonTools", targets: ["ErgonTools"]),
    ],
    targets: [
        .target(name: "Ergon"),
        .target(name: "ErgonTools", dependencies: ["Ergon"]),
        .testTarget(name: "ErgonTests", dependencies: ["Ergon"]),
    ]
)
