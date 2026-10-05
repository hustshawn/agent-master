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
///     POST   /api/sessions/{id}/files?name=            any file as the body, kept with the session: AttachmentJSON
///     GET    /api/sessions/{id}/files/{attachment}     the file, to preview or download
///     GET    /api/uploads/limits                       UploadLimitsJSON: largest file, attachments per message
///     GET    /api/sessions/{id}/chat?after=            the conversation as ChatJSON; replace from `start`
///     POST   /api/sessions/{id}/messages              {"id", "text", "attachments"?: [id]}: types a prompt;
///                                                      MessageReceiptJSON (409 if busy)
///     PUT    /api/sessions/{id}/reviewed               {"reviewed": bool}: marks the last turn's result reviewed
///     POST   /api/sessions/{id}/interrupt              stops the current turn (Esc)
///     GET    /api/requests                             open and recently resolved approvals and questions
///     POST   /api/requests/{id}                        {"behavior": "allow"|"deny", "message"?} or {"answers": {question: label}};
///                                                      ActionRequestJSON (409 once answered or expired)
///     GET    /api/push/key                             {"publicKey"}: the VAPID key for pushManager.subscribe
///     GET    /api/push/subscriptions                   {"subscriptions": [{"endpoint", "label", "createdAt"}]}
///     POST   /api/push/subscriptions                   a PushSubscription's JSON plus "label"
///     DELETE /api/push/subscriptions                   {"endpoint"}
///     POST   /api/push/test                            sends a test notification to every device
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
        router.middlewares.add(RevalidateMiddleware())
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
        api.post("sessions/:id/files") { request, context -> AttachmentJSON in
            let limit = UploadLimitsJSON.current.maxFileBytes
            let body: ByteBuffer
            do {
                body = try await request.body.collect(upTo: limit)
            } catch is NIOTooManyBytesError {
                throw HTTPError(.contentTooLarge, message: "Files can be at most \(limit / 1024 / 1024) MB.")
            }
            let contentType = request.headers[.contentType]?.split(separator: ";").first.map(String.init) ?? ""
            return try mapErrors {
                try manager.saveFile(sessionId: context.parameters.require("id"), data: Data(body.readableBytesView),
                                     filename: request.uri.queryParameters.get("name") ?? "file", contentType: contentType)
            }
        }
        api.get("sessions/:id/files/:file") { _, context -> Response in
            let (attachment, data) = try mapErrors {
                try manager.attachment(sessionId: context.parameters.require("id"), id: context.parameters.require("file"))
            }
            return attachmentResponse(attachment, data: data)
        }
        api.get("uploads/limits") { _, _ in UploadLimitsJSON.current }
        api.delete("sessions/:id") { _, context -> HTTPResponse.Status in
            try mapErrors { try manager.close(id: context.parameters.require("id")) }
            return .noContent
        }
        api.get("sessions/:id/chat") { request, context -> ChatJSON in
            let after = request.uri.queryParameters.get("after").flatMap { Int($0) } ?? 0
            return try mapErrors { try manager.chat(sessionId: context.parameters.require("id"), after: after) }
        }
        api.post("sessions/:id/messages") { request, context -> MessageReceiptJSON in
            let body = try await request.decode(as: MessageRequest.self, context: context)
            return try mapErrors {
                try manager.send(sessionId: context.parameters.require("id"), messageId: body.id, text: body.text,
                                 attachmentIds: body.attachments ?? [])
            }
        }
        api.put("sessions/:id/reviewed") { request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: ReviewedRequest.self, context: context)
            try mapErrors { try manager.setReviewed(id: context.parameters.require("id"), body.reviewed) }
            return .noContent
        }
        api.post("sessions/:id/interrupt") { _, context -> HTTPResponse.Status in
            try mapErrors { try manager.interrupt(sessionId: context.parameters.require("id")) }
            return .noContent
        }

        api.get("requests") { _, _ in RequestsResponse(requests: manager.actionRequests) }
        api.post("requests/:id") { request, context -> ActionRequestJSON in
            let body = try await request.decode(as: AnswerRequest.self, context: context)
            let decision: RemoteDecision
            if let answers = body.answers {
                decision = .answer(answers)
            } else if body.behavior == "allow" {
                decision = .allow
            } else if body.behavior == "deny" {
                decision = .deny(message: body.message ?? "The user denied this.", interrupt: false)
            } else {
                throw HTTPError(.badRequest, message: "Send behavior allow or deny, or answers.")
            }
            return try mapErrors { try manager.answer(requestId: context.parameters.require("id"), decision: decision) }
        }

        api.get("push/key") { _, _ in PushKeyResponse(publicKey: manager.push.publicKey) }
        api.get("push/subscriptions") { _, _ in
            PushSubscriptionsResponse(subscriptions: manager.push.store.list().map {
                .init(endpoint: $0.endpoint, label: $0.label, createdAt: $0.createdAt.timeIntervalSince1970)
            })
        }
        api.post("push/subscriptions") { request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: SubscribeRequest.self, context: context)
            guard URL(string: body.endpoint)?.scheme == "https" else {
                throw HTTPError(.badRequest, message: "A push endpoint must be an https URL.")
            }
            manager.push.store.add(PushSubscription(endpoint: body.endpoint, keys: body.keys, label: body.label))
            return .noContent
        }
        api.delete("push/subscriptions") { request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: UnsubscribeRequest.self, context: context)
            manager.push.store.remove(endpoint: body.endpoint)
            return .noContent
        }
        api.post("push/test") { _, _ -> HTTPResponse.Status in
            manager.push.sendTest()
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
            // Read after subscribing, so a request or receipt that changes meanwhile arrives twice at worst.
            try await outbound.write(.text(json(ServerEvent(type: "snapshot", sessions: sessions,
                                                            requests: manager.actionRequests,
                                                            messages: manager.messageReceipts))))
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

    /// Types a browser shows itself without running anything; everything else is downloaded.
    static let inlineTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf", "text/plain"]

    /// An uploaded file served back from this origin, which holds the token: it is never a page that can run
    /// script here (no inline HTML or SVG, sandboxed, no type sniffing).
    static func attachmentResponse(_ attachment: AttachmentJSON, data: Data) -> Response {
        let inline = inlineTypes.contains(attachment.type)
        let encodedName = attachment.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        var headers = HTTPFields()
        headers[.contentType] = inline ? attachment.type : "application/octet-stream"
        headers[.contentDisposition] = "\(inline ? "inline" : "attachment"); filename*=UTF-8''\(encodedName)"
        headers[.contentSecurityPolicy] = "sandbox"
        headers[.init("X-Content-Type-Options")!] = "nosniff"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

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
        } catch let error as MessageError {
            if case .empty = error { throw HTTPError(.badRequest, message: error.description) }
            throw HTTPError(.conflict, message: error.description)
        } catch let error as ActionRequestError {
            switch error {
            case .unknown: throw HTTPError(.notFound, message: error.description)
            case .notPending: throw HTTPError(.conflict, message: error.description)
            case .unsupportedDecision: throw HTTPError(.badRequest, message: error.description)
            }
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

/// The page's files are cached but always revalidated (a cheap 304 by ETag), so after an upgrade a browser
/// never pairs a new index.html with an old app.js and shows a blank page.
struct RevalidateMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var response = try await next(request, context)
        if !request.uri.path.hasPrefix("/api/") { response.headers[.cacheControl] = "no-cache" }
        return response
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

struct ReviewedRequest: Decodable {
    let reviewed: Bool
}

struct MessageRequest: Decodable {
    let id: String
    let text: String
    /// Ids from POST /api/sessions/{id}/files, sent with the text.
    let attachments: [String]?
}

struct AnswerRequest: Decodable {
    let behavior: String?
    let message: String?
    let answers: [String: String]?
}

struct RequestsResponse: ResponseEncodable {
    let requests: [ActionRequestJSON]
}

struct PushKeyResponse: ResponseEncodable {
    let publicKey: String
}

struct PushSubscriptionsResponse: ResponseEncodable {
    struct Device: Codable {
        let endpoint: String
        let label: String?
        let createdAt: Double
    }

    let subscriptions: [Device]
}

struct SubscribeRequest: Decodable {
    let endpoint: String
    let keys: PushSubscription.Keys
    let label: String?
}

struct UnsubscribeRequest: Decodable {
    let endpoint: String
}

extension SessionJSON: ResponseEncodable {}
extension MessageReceiptJSON: ResponseEncodable {}
extension ChatJSON: ResponseEncodable {}
extension AttachmentJSON: ResponseEncodable {}
extension UploadLimitsJSON: ResponseEncodable {}
extension ActionRequestJSON: ResponseEncodable {}

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
