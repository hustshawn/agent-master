import XCTest
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import AgentMasterBridge
@testable import AgentMasterServerKit

/// The HTTP API end to end, in memory, over a manager whose `claude` is a stand-in script.
final class WebServerTests: XCTestCase {
    private var root: URL!
    private var manager: SessionManager!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/am-web-\(UUID().uuidString.prefix(8))")
        for (path, body) in [("bin/claude", "#!/bin/sh\nexec cat\n"), ("server/agentmaster-hook", "#!/bin/sh\n")] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: true)
        try Data("<!doctype html><title>AgentMaster</title>".utf8).write(to: root.appendingPathComponent("web/index.html"))
        manager = try SessionManager(.init(
            dataDirectory: root.appendingPathComponent("data"),
            executableURL: root.appendingPathComponent("server/agentmaster-server"),
            environment: ["PATH": "/usr/bin:/bin", "AGENTMASTER_CLAUDE_PATH": root.appendingPathComponent("bin/claude").path]))
    }

    override func tearDown() {
        manager.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    private func app() -> some ApplicationProtocol {
        WebServer.makeApplication(manager: manager, token: "secret", host: "127.0.0.1", port: 0,
                                  webRoot: root.appendingPathComponent("web").path, logger: Logger(label: "test"))
    }

    private let auth: HTTPFields = [.authorization: "Bearer secret", .contentType: "application/json"]

    func testTheApiNeedsTheTokenButThePageDoesNot() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/api/sessions", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            try await client.execute(uri: "/api/sessions", method: .get, headers: [.authorization: "Bearer nope"]) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "/api/sessions?token=secret", method: .get) { XCTAssertEqual($0.status, .ok) }
            try await client.execute(uri: "/", method: .get) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertTrue(String(buffer: $0.body).contains("AgentMaster"))
            }
        }
    }

    func testSessionsCanBeCreatedRenamedListedAndClosed() async throws {
        let project = SessionManager.realPath(root.appendingPathComponent("project").path)
        try await app().test(.router) { client in
            let body = ByteBuffer(string: #"{"projectPath":"\#(project)","agentId":"claude","columns":100,"rows":30}"#)
            let created = try await client.execute(uri: "/api/sessions", method: .post, headers: self.auth, body: body) {
                XCTAssertEqual($0.status, .ok)
                return try JSONDecoder().decode(SessionJSON.self, from: Data(buffer: $0.body))
            }
            XCTAssertEqual(created.projectPath, project)
            try await client.execute(uri: "/api/sessions/\(created.id)", method: .patch, headers: self.auth,
                                     body: ByteBuffer(string: #"{"name":"Renamed"}"#)) { XCTAssertEqual($0.status, .noContent) }
            try await client.execute(uri: "/api/sessions", method: .get, headers: self.auth) {
                let list = try JSONDecoder().decode([String: [SessionJSON]].self, from: Data(buffer: $0.body))
                XCTAssertEqual(list["sessions"]?.map(\.title), ["Renamed"])
            }
            try await client.execute(uri: "/api/sessions/\(created.id)", method: .delete, headers: self.auth) {
                XCTAssertEqual($0.status, .noContent)
            }
            try await client.execute(uri: "/api/sessions/\(created.id)", method: .delete, headers: self.auth) {
                XCTAssertEqual($0.status, .badRequest)
            }
        }
    }

    func testAnUploadedImageIsSavedWithTheSessionUntilItCloses() async throws {
        let project = SessionManager.realPath(root.appendingPathComponent("project").path)
        let session = try manager.create(projectPath: project, agentId: "claude")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try await app().test(.router) { client in
            let path = try await client.execute(uri: "/api/sessions/\(session.id)/images", method: .post,
                                                headers: [.authorization: "Bearer secret", .contentType: "image/png"],
                                                body: ByteBuffer(bytes: png)) {
                XCTAssertEqual($0.status, .ok)
                return try JSONDecoder().decode([String: String].self, from: Data(buffer: $0.body))["path"] ?? ""
            }
            XCTAssertTrue(path.hasSuffix(".png"))
            XCTAssertEqual(FileManager.default.contents(atPath: path), png)

            try await client.execute(uri: "/api/sessions/\(session.id)/images", method: .post,
                                     headers: [.authorization: "Bearer secret", .contentType: "text/plain"],
                                     body: ByteBuffer(string: "hi")) { XCTAssertEqual($0.status, .badRequest) }
            try await client.execute(uri: "/api/sessions/nope/images", method: .post,
                                     headers: [.authorization: "Bearer secret", .contentType: "image/png"],
                                     body: ByteBuffer(bytes: png)) { XCTAssertEqual($0.status, .badRequest) }
            try await client.execute(uri: "/api/sessions/\(session.id)/images", method: .post,
                                     headers: [.authorization: "Bearer secret", .contentType: "image/png"],
                                     body: ByteBuffer(repeating: 0, count: WebServer.maxImageBytes + 1)) {
                XCTAssertEqual($0.status, .contentTooLarge)
            }

            try manager.close(id: session.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testAnyFileCanBeUploadedUnderASafeVersionOfItsName() async throws {
        let project = SessionManager.realPath(root.appendingPathComponent("project").path)
        let session = try manager.create(projectPath: project, agentId: "claude")
        try await app().test(.router) { client in
            let path = try await client.execute(uri: "/api/sessions/\(session.id)/files?name=crash%20log%20(1).txt", method: .post,
                                                headers: [.authorization: "Bearer secret", .contentType: "text/plain"],
                                                body: ByteBuffer(string: "boom")) {
                XCTAssertEqual($0.status, .ok)
                return try JSONDecoder().decode([String: String].self, from: Data(buffer: $0.body))["path"] ?? ""
            }
            XCTAssertTrue(path.hasSuffix("-crash-log--1-.txt"), path)
            XCTAssertFalse(path.contains(" "), "one word in the prompt")
            XCTAssertEqual(FileManager.default.contents(atPath: path), Data("boom".utf8))
            try await client.execute(uri: "/api/sessions/\(session.id)/files", method: .post,
                                     headers: [.authorization: "Bearer secret"],
                                     body: ByteBuffer(repeating: 0, count: WebServer.maxFileBytes + 1)) {
                XCTAssertEqual($0.status, .contentTooLarge)
            }
            try manager.close(id: session.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertEqual(SessionManager.safeFilename("../../etc/passwd"), "passwd")
        XCTAssertEqual(SessionManager.safeFilename("截图 1.PNG"), "截图-1.PNG")
        XCTAssertEqual(SessionManager.safeFilename(""), "file")
    }

    func testAMissingFolderIsABadRequestWithAMessage() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/api/sessions", method: .post, headers: self.auth,
                                     body: ByteBuffer(string: #"{"projectPath":"/definitely/not/here"}"#)) {
                XCTAssertEqual($0.status, .badRequest)
                XCTAssertTrue(String(buffer: $0.body).contains("is not a folder"))
            }
        }
    }

    func testAgentSettingsRoundTrip() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/api/agents/claude/options/permissionMode", method: .put, headers: self.auth,
                                     body: ByteBuffer(string: #"{"value":"bypassPermissions"}"#)) {
                XCTAssertEqual($0.status, .noContent)
            }
            try await client.execute(uri: "/api/agents", method: .get, headers: self.auth) {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as? [String: Any])
                let agents = try XCTUnwrap(json["agents"] as? [[String: Any]])
                XCTAssertEqual(agents.map { $0["id"] as? String }, AgentRegistry.all.map(\.id))
                let claude = agents[0]
                XCTAssertEqual((claude["preferences"] as? [String: String])?["permissionMode"], "bypassPermissions")
                XCTAssertEqual(claude["forcedOn"] as? [String], ["allowBypass"], "bypass mode forces the bypass toggle")
                XCTAssertNotNil(claude["location"], "the stand-in claude was found through the override")
            }
            try await client.execute(uri: "/api/general", method: .put, headers: self.auth,
                                     body: ByteBuffer(string: #"{"restoreSessionsOnLaunch":false}"#)) {
                XCTAssertEqual($0.status, .noContent)
            }
            XCTAssertFalse(self.manager.restoreSessionsOnLaunch)
        }
    }

    func testFoldersListsTheServersDirectories() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/api/folders?path=\(self.root.path)", method: .get, headers: self.auth) {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as? [String: Any])
                let names = (json["folders"] as? [[String: String]])?.compactMap { $0["name"] }
                XCTAssertEqual(names, ["bin", "data", "project", "server", "web"])
            }
        }
    }
}
