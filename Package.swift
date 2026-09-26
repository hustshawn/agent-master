// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentMaster", targets: ["AgentMaster"]),
        .executable(name: "agentmaster-hook", targets: ["agentmaster-hook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.18.0"),
    ],
    targets: [
        .target(name: "AgentMasterCore"),
        .target(name: "AgentMasterWire", dependencies: ["AgentMasterCore"]),
        .executableTarget(name: "agentmaster-hook", dependencies: ["AgentMasterWire"]),
        .target(name: "AgentMasterBridge", dependencies: ["AgentMasterCore", "AgentMasterWire"]),
        .target(name: "TerminalKit", dependencies: ["AgentMasterCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "AgentMasterUI", dependencies: ["AgentMasterCore"]),
        .executableTarget(name: "AgentMaster",
                          dependencies: ["AgentMasterCore", "AgentMasterWire", "AgentMasterBridge", "TerminalKit", "AgentMasterUI"]),
        .testTarget(name: "AgentMasterCoreTests", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterWireTests", dependencies: ["AgentMasterWire"]),
        .testTarget(name: "AgentMasterBridgeTests", dependencies: ["AgentMasterBridge"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit"]),
        .testTarget(name: "AgentMasterUITests", dependencies: ["AgentMasterUI"]),
    ]
)
