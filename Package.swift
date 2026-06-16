// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PerfectCRUD",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PerfectCRUD", targets: ["PerfectCRUD"])
    ],
    dependencies: [],
    targets: [
        .target(name: "PerfectCRUD", dependencies: [])
    ]
)
