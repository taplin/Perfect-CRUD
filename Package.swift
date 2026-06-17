// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PerfectCRUD",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "PerfectCRUD", targets: ["PerfectCRUD"])
    ],
    dependencies: [],
    targets: [
        .target(name: "PerfectCRUD", dependencies: [])
    ]
)
