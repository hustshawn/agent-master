// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentmaster-hook", targets: ["agentmaster-hook"]),
        .executable(name: "agentmaster-server", targets: ["agentmaster-server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "AgentMasterCore"),
        .target(name: "AgentMasterWire", dependencies: ["AgentMasterCore"]),
        .executableTarget(name: "agentmaster-hook", dependencies: ["AgentMasterWire"]),
        .target(name: "AgentMasterBridge", dependencies: ["AgentMasterCore", "AgentMasterWire"]),

        // The web edition: a server that runs the agents in pseudo-terminals and a browser UI (macOS and Linux).
        .target(name: "CPTY", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
        .target(name: "AgentMasterServerKit",
                dependencies: ["AgentMasterCore", "AgentMasterWire", "AgentMasterBridge", "CPTY",
                               .product(name: "Hummingbird", package: "hummingbird"),
                               .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket")],
                resources: [.copy("Web")]),
        .executableTarget(name: "agentmaster-server", dependencies: ["AgentMasterServerKit"]),

        .testTarget(name: "AgentMasterCoreTests", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterWireTests", dependencies: ["AgentMasterWire"]),
        .testTarget(name: "AgentMasterBridgeTests", dependencies: ["AgentMasterBridge"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "AgentMasterServerTests",
                    dependencies: ["AgentMasterServerKit", "AgentMasterBridge",
                                   .product(name: "HummingbirdTesting", package: "hummingbird")]),
    ]
)

// The Mac app (AppKit, SwiftUI, SwiftTerm) builds only on macOS; Linux gets the server and what it shares.
#if os(macOS)
package.products.insert(.executable(name: "AgentMaster", targets: ["AgentMaster"]), at: 0)
package.dependencies.insert(.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.18.0"), at: 0)
package.targets += [
    .target(name: "TerminalKit", dependencies: ["AgentMasterCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    .target(name: "AgentMasterUI", dependencies: ["AgentMasterCore"]),
    .executableTarget(name: "AgentMaster",
                      dependencies: ["AgentMasterCore", "AgentMasterWire", "AgentMasterBridge", "TerminalKit", "AgentMasterUI"]),
    .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit"]),
    .testTarget(name: "AgentMasterUITests", dependencies: ["AgentMasterUI"]),
]
#endif
