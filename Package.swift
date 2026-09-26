// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentmaster-hook", targets: ["agentmaster-hook"]),
    ],
    targets: [
        .target(name: "AgentMasterCore"),
        .target(name: "AgentMasterWire", dependencies: ["AgentMasterCore"]),
        .executableTarget(name: "agentmaster-hook", dependencies: ["AgentMasterWire"]),
        .target(name: "AgentMasterBridge", dependencies: ["AgentMasterCore", "AgentMasterWire"]),
        .testTarget(name: "AgentMasterCoreTests", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterWireTests", dependencies: ["AgentMasterWire"]),
        .testTarget(name: "AgentMasterBridgeTests", dependencies: ["AgentMasterBridge"],
                    resources: [.copy("Fixtures")]),
    ]
)
