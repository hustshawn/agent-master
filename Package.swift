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
        // Web Push encryption. Already in the graph through Hummingbird; 5.x needs Swift 6.2, so allow older.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        // Sends Web Push over SwiftNIO; already in the graph through HummingbirdTesting.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        // Already in the graph through Hummingbird; 1.1.3 and later use `#isolation` and no longer build with Swift 5.10.
        .package(url: "https://github.com/apple/swift-async-algorithms.git", "1.0.2"..<"1.1.3"),
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
                               .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                               .product(name: "Crypto", package: "swift-crypto"),
                               .product(name: "AsyncHTTPClient", package: "async-http-client"),
                               .product(name: "AsyncAlgorithms", package: "swift-async-algorithms")],
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
