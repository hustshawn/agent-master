import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import Logging
import AgentMasterBridge

/// The browser's API. Every /api route needs the server token, as `Authorization: Bearer <token>`
/// or, for WebSockets (which cannot set headers from a browser), `?token=<token>`.
///
///     GET    /api/agents                               agents, their settings, and General settings
///     PUT    /api/agents/{agent}/options/{option}      {"value": "..."|null}
///     PUT    /api/general                              {"restoreSessionsOnLaunch": bool}
///     GET    /api/sessions                             every session
///     POST   /api/sessions                             {"projectPath", "agentId"?, "model"?, "columns"?, "rows"?}
///     PATCH  /api/sessions/{id}                        {"name": "..."}
///     DELETE /api/sessions/{id}
///     POST   /api/sessions/{id}/images                 an image as the body (Content-Type image/*): {"path"}
///     GET    /api/recents                              recent project folders
///     GET    /api/folders?path=                        subfolders of a server folder, for the folder picker
///     WS     /api/events                               ServerEvent JSON: a snapshot, then every change
///     WS     /api/terminal?id=                         binary terminal output (scrollback first); send
///                                                      {"type":"input","data"} or {"type":"resize","columns","rows"}
public enum WebServer {
    public static func makeApplication(manager: SessionManager, token: String, host: String, port: Int,
                                       webRoot: String, logger: Logger) -> some ApplicationProtocol {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.middlewares.add(TokenMiddleware(token: token))
        router.middlewares.add(FileMiddleware(webRoot, searchForIndexHtml: true))
        addRoutes(to: router, manager: manager)
        return Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname(host, port: port), serverName: "agentmaster-server"),
            logger: logger)
    }

    static func addRoutes(to router: Router<BasicWebSocketRequestContext>, manager: SessionManager) {
        let api = router.group("api")

        api.get("agents") { _, _ in
            AgentsResponse(agents: manager.agents(), restoreSessionsOnLaunch: manager.restoreSessionsOnLaunch,
                           home: NSHomeDirectory())
        }
        api.put("agents/:agent/options/:option") { request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: OptionRequest.self, context: context)
            try mapErrors {
                try manager.setOption(agentId: context.parameters.require("agent"),
                                      optionId: context.parameters.require("option"), value: body.value)
            }
            return .noContent
        }
        api.put("general") { request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: GeneralRequest.self, context: context)
            manager.restoreSessionsOnLaunch = body.restoreSessionsOnLaunch
            return .noContent
        }

        api.get("sessions") { _, _ in SessionsResponse(sessions: manager.list()) }
        api.post("sessions") { request, context -> SessionJSON in
            let body = try await request.decode(as: CreateSessionRequest.self, context: context)
            return try mapErrors {
                try manager.create(projectPath: body.projectPath, agentId: body.agentId, model: body.model,
                                   columns: body.columns ?? 120, rows: body.rows ?? 36)
            }
        }
        api.patch("sessions/:id") { request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: RenameRequest.self, context: context)
            try mapErrors { try manager.rename(id: context.parameters.require("id"), to: body.name) }
            return .noContent
        }
        api.post("sessions/:id/images") { request, context -> ImageResponse in
            let body: ByteBuffer
            do {
                body = try await request.body.collect(upTo: maxImageBytes)
            } catch is NIOTooManyBytesError {
                throw HTTPError(.contentTooLarge, message: "Images can be at most \(maxImageBytes / 1024 / 1024) MB.")
            }
            let contentType = request.headers[.contentType]?.split(separator: ";").first.map(String.init) ?? ""
            return try mapErrors {
                ImageResponse(path: try manager.saveImage(sessionId: context.parameters.require("id"),
                                                          data: Data(body.readableBytesView), contentType: contentType))
            }
        }
        api.delete("sessions/:id") { _, context -> HTTPResponse.Status in
            try mapErrors { try manager.close(id: context.parameters.require("id")) }
            return .noContent
        }

        api.get("recents") { _, _ in RecentsResponse(paths: manager.recentProjects) }
        api.get("folders") { request, _ in
            try FolderListing.list(request.uri.queryParameters.get("path") ?? NSHomeDirectory())
        }

        router.ws("api/events") { _, _ in
            .upgrade()
        } onUpgrade: { inbound, outbound, _ in
            let (stream, continuation) = AsyncStream<ServerEvent>.makeStream(bufferingPolicy: .unbounded)
            let (token, sessions) = manager.subscribe { continuation.yield($0) }
            defer {
                manager.unsubscribe(token)
                continuation.finish()
            }
            try await outbound.write(.text(json(ServerEvent(type: "snapshot", sessions: sessions))))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in stream { try await outbound.write(.text(json(event))) }
                }
                group.addTask {
                    for try await _ in inbound {}   // returns when the browser goes away
                }
                try await group.next()
                group.cancelAll()
            }
        }

        router.ws("api/terminal") { request, _ in
            guard let id = request.uri.queryParameters.get("id"), manager.session(id: id) != nil else { return .dontUpgrade }
            return .upgrade()
        } onUpgrade: { inbound, outbound, context in
            guard let id = context.request.uri.queryParameters.get("id"), let session = manager.session(id: id) else { return }
            try await TerminalBridge.run(session: session, inbound: inbound, outbound: outbound)
        }
    }

    static let maxImageBytes = 20 * 1024 * 1024

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// The manager's errors are the browser's fault (a missing folder, an unknown id): report them as 400s.
    static func mapErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SessionManagerError {
            throw HTTPError(.badRequest, message: error.description)
        } catch let error as AgentLaunchError {
            throw HTTPError(.badRequest, message: error.localizedDescription)
        } catch let error as PTYProcess.SpawnError {
            throw HTTPError(.internalServerError, message: error.description)
        }
    }
}

/// Wires one browser terminal to one session's pseudo-terminal.
enum TerminalBridge {
    struct Control: Decodable {
        let type: String
        let data: String?
        let columns: UInt16?
        let rows: UInt16?
    }

    /// Frames stay well under the default WebSocket frame limits.
    static let chunkSize = 64 * 1024

    static func run(session: ServerSession, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let (token, scrollback) = session.process.subscribe { continuation.yield($0) }
        defer {
            session.process.unsubscribe(token)
            continuation.finish()
        }
        for start in stride(from: 0, to: scrollback.count, by: chunkSize) {
            let chunk = scrollback[(scrollback.startIndex + start)..<min(scrollback.endIndex, scrollback.startIndex + start + chunkSize)]
            try await outbound.write(.binary(ByteBuffer(bytes: chunk)))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await data in stream {
                    for start in stride(from: 0, to: data.count, by: chunkSize) {
                        let chunk = data[(data.startIndex + start)..<min(data.endIndex, data.startIndex + start + chunkSize)]
                        try await outbound.write(.binary(ByteBuffer(bytes: chunk)))
                    }
                }
            }
            group.addTask {
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    switch message {
                    case .text(let text):
                        guard let control = try? JSONDecoder().decode(Control.self, from: Data(text.utf8)) else { continue }
                        if control.type == "input", let data = control.data {
                            session.process.write(Data(data.utf8))
                        } else if control.type == "resize", let columns = control.columns, let rows = control.rows {
                            session.process.resize(columns: columns, rows: rows)
                        }
                    case .binary(var buffer):
                        if let bytes = buffer.readBytes(length: buffer.readableBytes) { session.process.write(Data(bytes)) }
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

/// `/api` needs the token; the static page does not (it holds no data and asks for the token itself).
struct TokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard request.uri.path.hasPrefix("/api/") else { return try await next(request, context) }
        let bearer = request.headers[.authorization].flatMap { header -> String? in
            header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : nil
        }
        let presented = bearer ?? request.uri.queryParameters.get("token") ?? ""
        guard Self.constantTimeEqual(presented, token) else { throw HTTPError(.unauthorized, message: "Missing or wrong token.") }
        return try await next(request, context)
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct AgentsResponse: ResponseEncodable {
    let agents: [AgentJSON]
    let restoreSessionsOnLaunch: Bool
    let home: String
}

struct SessionsResponse: ResponseEncodable {
    let sessions: [SessionJSON]
}

struct ImageResponse: ResponseEncodable {
    let path: String
}

struct RecentsResponse: ResponseEncodable {
    let paths: [String]
}

struct OptionRequest: Decodable {
    let value: String?
}

struct GeneralRequest: Decodable {
    let restoreSessionsOnLaunch: Bool
}

struct CreateSessionRequest: Decodable {
    let projectPath: String
    let agentId: String?
    let model: String?
    let columns: UInt16?
    let rows: UInt16?
}

struct RenameRequest: Decodable {
    let name: String
}

extension SessionJSON: ResponseEncodable {}

/// Subfolders of one folder on the server, for choosing where a session runs.
struct FolderListing: ResponseEncodable {
    struct Entry: Codable {
        let name: String
        let path: String
    }

    let path: String
    let parent: String?
    let folders: [Entry]

    static func list(_ rawPath: String) throws -> FolderListing {
        let path = SessionManager.expandingTilde(rawPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HTTPError(.badRequest, message: "\(path) is not a folder on the server.")
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let folders = names.filter { !$0.hasPrefix(".") }.compactMap { name -> Entry? in
            let child = (path as NSString).appendingPathComponent(name)
            var childIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child, isDirectory: &childIsDirectory), childIsDirectory.boolValue
            else { return nil }
            return Entry(name: name, path: child)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let parent = path == "/" ? nil : (path as NSString).deletingLastPathComponent
        return FolderListing(path: path, parent: parent, folders: folders)
    }
}
