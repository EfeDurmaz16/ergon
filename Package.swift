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
        // Service descriptors ship as JSON, not as Swift: a remote service is
        // data, and bundling it as a resource is the first step toward one
        // arriving at runtime.
        .target(name: "ErgonTools", dependencies: ["Ergon"],
                resources: [.process("Services")]),
        .target(name: "ErgonUI", dependencies: ["Ergon"]),
        .testTarget(name: "ErgonTests", dependencies: ["Ergon", "ErgonTools", "ErgonUI"]),
    ]
)
