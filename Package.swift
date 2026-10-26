// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shipper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Shipper"),
        .testTarget(name: "ShipperTests", dependencies: ["Shipper"]),
    ]
)
