// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Ergon",
    platforms: [.iOS("26.1"), .macOS("26.0")],
    products: [
        .library(name: "Ergon", targets: ["Ergon"]),
        .library(name: "ErgonTools", targets: ["ErgonTools"]),
        .library(name: "ErgonUI", targets: ["ErgonUI"]),
    ],
    targets: [
        .target(name: "Ergon"),
        .target(name: "ErgonTools", dependencies: ["Ergon"]),
        .target(name: "ErgonUI", dependencies: ["Ergon"]),
        .testTarget(name: "ErgonTests", dependencies: ["Ergon", "ErgonTools", "ErgonUI"]),
    ]
)
