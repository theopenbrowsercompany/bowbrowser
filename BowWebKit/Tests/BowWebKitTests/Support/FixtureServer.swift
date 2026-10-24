import Foundation
import Network

/// The tests' loopback fixture server: plain HTTP on 127.0.0.1 (and ::1, so `localhost` resolves either way) at a
/// random port. It serves the test target's `Fixtures/` folder, `/log` (every request so far, as JSON), and the
/// routes a test registers with `route(_:_:)`, so each area adds its own (a redirect, a login, a 401) in its own
/// test file. `otherBase` (`localhost`) is a second origin for cross origin checks.
///
/// Start one per test and stop it at the end; it keeps no state between servers.
final class FixtureServer: @unchecked Sendable {
    struct Request: Codable, Sendable {
        var method: String
        var host: String
        /// The request target: the path with its query.
        var target: String
        var headers: [String: String]
        var time: Double

        /// The path without its query.
        var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "/") }
        var cookie: String { headers["cookie"] ?? "" }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String] = []
        var body = Data()
        /// Seconds to hold the answer, as a slow server would; `.infinity` never answers (the connection stays open
        /// until the server stops), for a load that is still going when the test acts.
        var delay: Double = 0
        /// Sends the body `bytes` at a time, `interval` seconds apart, as a slow network would, so a test can act
        /// while it is still arriving; nil sends it at once.
        var pace: Pace?

        struct Pace: Sendable {
            var bytes: Int
            var interval: Double
            /// When set, the server sends the first `heldAfter` bytes of the body and holds the rest until the test
            /// opens the gate, so a test acts on a download that cannot finish meanwhile, however loaded the machine.
            var gate: Gate?
            var heldAfter = 0
        }

        static func html(_ text: String, status: Int = 200, headers: [String] = []) -> Response {
            Response(
                status: status, headers: ["Content-Type: text/html; charset=utf-8"] + headers, body: Data(text.utf8))
        }

        static func redirect(to location: String, status: Int = 302) -> Response {
            Response(status: status, headers: ["Location: \(location)"])
        }

        static let notFound = Response(
            status: 404, headers: ["Content-Type: text/plain"], body: Data("not found".utf8))
    }

    /// A gate the test owns: a paced answer that reached its `heldAfter` bytes waits here until `open()`.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [@Sendable () -> Void] = []

        /// Lets every held answer go on, and every later one pass.
        func open() {
            lock.lock()
            isOpen = true
            let waiting = self.waiting
            self.waiting = []
            lock.unlock()
            for resume in waiting { resume() }
        }

        /// Runs `body` now when the gate is open, else once it opens.
        fileprivate func pass(_ body: @escaping @Sendable () -> Void) {
            lock.lock()
            guard isOpen else {
                waiting.append(body)
                return lock.unlock()
            }
            lock.unlock()
            body()
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    private let root: URL
    private let queue = DispatchQueue(label: "bowwebkit.fixture-server")
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var routes: [String: Handler] = [:]
    private var requests: [Request] = []
    private var bound: UInt16 = 0

    /// A server for `root`, by default the test target's `Fixtures/` folder.
    init(root: URL? = nil) {
        self.root = root ?? Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    /// Starts a server and returns it.
    static func started() throws -> FixtureServer {
        let server = FixtureServer()
        try server.start()
        return server
    }

    var port: UInt16 { locked { bound } }
    var base: String { "http://127.0.0.1:\(port)" }
    var otherBase: String { "http://localhost:\(port)" }

    func url(_ path: String) -> URL { URL(string: base + path)! }

    /// Answers requests whose path (without the query) is `path` with `handler`, in place of a fixture file.
    func route(_ path: String, _ handler: @escaping Handler) {
        locked { routes[path] = handler }
    }

    /// Every request so far, `/log` excepted.
    func log() -> [Request] { locked { requests } }

    /// How many requests had the path (without the query) `path`.
    func count(path: String) -> Int { log().filter { $0.path == path }.count }

    func start() throws {
        let first = try listener(host: "127.0.0.1", port: .any)
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: (any Error)?
        first.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            default: break
            }
        }
        first.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw TestError("fixture server did not start") }
        if let failure { throw failure }
        guard let port = first.port?.rawValue else { throw TestError("fixture server has no port") }
        locked {
            bound = port
            listeners.append(first)
        }
        // Best effort: localhost may resolve to ::1 first.
        if let second = try? listener(host: "::1", port: NWEndpoint.Port(rawValue: port)!) {
            second.start(queue: queue)
            locked { listeners.append(second) }
        }
    }

    /// Stops listening and closes every open connection, held answers included.
    func stop() {
        let (listeners, connections) = locked {
            defer {
                self.listeners = []
                self.connections = [:]
            }
            return (self.listeners, Array(self.connections.values))
        }
        for listener in listeners { listener.cancel() }
        for connection in connections { connection.cancel() }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func listener(host: String, port: NWEndpoint.Port) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.locked { self.connections[ObjectIdentifier(connection)] = connection }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        return listener
    }

    private func finish(_ connection: NWConnection) {
        locked { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
        connection.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let response = self.respond(to: head)
                guard response.delay.isFinite else { return }
                let send = {
                    if let pace = response.pace { return self.send(response, at: pace, on: connection) }
                    connection.send(
                        content: Self.encode(response), completion: .contentProcessed { _ in self.finish(connection) })
                }
                if response.delay > 0 {
                    self.queue.asyncAfter(deadline: .now() + response.delay, execute: send)
                } else {
                    send()
                }
                return
            }
            if complete || error != nil { return self.finish(connection) }
            self.receive(connection, buffer: buffer)
        }
    }

    /// Sends the head with the first piece of the body, then a piece every `pace.interval` seconds, holding at
    /// `pace.heldAfter` body bytes until `pace.gate` opens; stops when the client went away or the server stopped.
    private func send(_ response: Response, at pace: Pace, on connection: NWConnection) {
        let data = Self.encode(response)
        let head = data.count - response.body.count
        @Sendable func piece(from start: Int) {
            if let gate = pace.gate, start > 0, start >= head + pace.heldAfter {
                return gate.pass { self.queue.async { send(from: start) } }
            }
            send(from: start)
        }
        @Sendable func send(from start: Int) {
            let end = min(data.count, (start == 0 ? head : start) + max(pace.bytes, 1))
            connection.send(
                content: data.subdata(in: start..<end),
                completion: .contentProcessed { error in
                    guard error == nil, end < data.count else { return self.finish(connection) }
                    self.queue.asyncAfter(deadline: .now() + pace.interval) { piece(from: end) }
                })
        }
        piece(from: 0)
    }

    typealias Pace = Response.Pace

    private func respond(to head: String) -> Response {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ").map(String.init)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
                in: .whitespaces)
        }
        let request = Request(
            method: parts.first ?? "GET", host: headers["host"] ?? "", target: parts.count > 1 ? parts[1] : "/",
            headers: headers, time: Date().timeIntervalSince1970)
        if request.path == "/log" {
            let body = (try? JSONEncoder().encode(log())) ?? Data("[]".utf8)
            return Response(status: 200, headers: ["Content-Type: application/json"], body: body)
        }
        let handler = locked {
            requests.append(request)
            return routes[request.path]
        }
        return handler?(request) ?? file(request.path, range: headers["range"] ?? "")
    }

    private func file(_ path: String, range: String) -> Response {
        let relative = path.removingPercentEncoding ?? path
        let url = root.appendingPathComponent(String(relative.drop(while: { $0 == "/" }))).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: url) else {
            return .notFound
        }
        let type = "Content-Type: " + (Self.types[url.pathExtension] ?? "application/octet-stream")
        // One range: `bytes=a-b`, `bytes=a-` (to the end) or `bytes=-n` (the last n bytes).
        if range.hasPrefix("bytes="), !data.isEmpty {
            let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let first = bounds.first.flatMap { Int($0) }
            let second = bounds.count > 1 ? Int(bounds[1]) : nil
            let start: Int
            let last: Int
            if let first {
                start = first
                last = min(second ?? (data.count - 1), data.count - 1)
            } else {
                start = max(data.count - (second ?? 0), 0)
                last = data.count - 1
            }
            if bounds.count == 2, first != nil || second != nil, start <= last {
                return Response(
                    status: 206,
                    headers: [type, "Content-Range: bytes \(start)-\(last)/\(data.count)", "Accept-Ranges: bytes"],
                    body: data.subdata(in: start..<(last + 1)))
            }
        }
        return Response(status: 200, headers: [type, "Accept-Ranges: bytes"], body: data)
    }

    private static let types = [
        "html": "text/html; charset=utf-8", "js": "text/javascript", "json": "application/json",
        "svg": "image/svg+xml", "webm": "video/webm", "png": "image/png", "css": "text/css",
    ]

    private static let reasons = [
        200: "OK", 204: "No Content", 206: "Partial Content", 301: "Moved Permanently", 302: "Found",
        303: "See Other", 307: "Temporary Redirect", 308: "Permanent Redirect", 401: "Unauthorized",
        403: "Forbidden", 404: "Not Found", 500: "Internal Server Error",
    ]

    private static func encode(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Status")\r\n"
        for line in response.headers { head += line + "\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
