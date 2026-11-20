// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shipper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "shipper-mcp", targets: ["ShipperChatGPTMCP"]),
    ],
    targets: [
        .executableTarget(name: "Shipper"),
        .executableTarget(name: "ShipperChatGPTMCP", path: "Sources/ShipperChatGPTMCP"),
        .testTarget(name: "ShipperTests", dependencies: ["Shipper"]),
    ]
)
