import Foundation
import Network
import Security

/// A loopback HTTPS server on 127.0.0.1 with a test only self signed identity made at test time (`localhost` and
/// 127.0.0.1), for the server trust tests. The identity is imported in memory only, never into a keychain, so no
/// Mac ever trusts it. Every request is answered by `handler`; `requests` lists the paths asked
/// for over a TLS connection the client accepted.
final class TLSListener: @unchecked Sendable {
    typealias Handler = @Sendable (_ path: String) -> FixtureServer.Response

    private let queue = DispatchQueue(label: "bowwebkit.tls-listener")
    private let lock = NSLock()
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var paths: [String] = []
    private var bound: UInt16 = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    static func started(handler: @escaping Handler) throws -> TLSListener {
        let server = TLSListener(handler: handler)
        try server.start()
        return server
    }

    var port: UInt16 { locked { bound } }
    func url(_ path: String) -> URL { URL(string: "https://127.0.0.1:\(port)\(path)")! }
    var requests: [String] { locked { paths } }

    /// The PKCS#12 data of a fresh self signed identity, made once per test process by the system's `openssl` in a
    /// scratch folder it removes. Made at test time, valid for 30 days, so it never expires in the repository and
    /// keeps within the validity Apple allows a server certificate (a longer one fails as too long, not untrusted).
    private static let identityData: Result<Data, TestError> = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bowwebkit-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let key = folder.appendingPathComponent("key.pem").path
            let cert = folder.appendingPathComponent("cert.pem").path
            let p12 = folder.appendingPathComponent("identity.p12").path
            try openssl([
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "30", "-subj", "/CN=localhost",
                "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-addext", "extendedKeyUsage=serverAuth",
                "-keyout", key, "-out", cert,
            ])
            try openssl([
                "pkcs12", "-export", "-inkey", key, "-in", cert, "-passout", "pass:\(passphrase)", "-certpbe",
                "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1", "-out", p12,
            ])
            return .success(try Data(contentsOf: URL(fileURLWithPath: p12)))
        } catch let error as TestError {
            return .failure(error)
        } catch {
            return .failure(TestError("could not make the test identity: \(error)"))
        }
    }()

    private static let passphrase = "bow-test"

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestError("openssl \(arguments.first ?? "") exited \(process.terminationStatus)")
        }
    }

    /// The test identity, imported in memory only.
    static func identity() throws -> SecIdentity {
        let data = try identityData.get()
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase, kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
            let identity = first[kSecImportItemIdentity as String]
        else { throw TestError("could not import the test identity: \(status)") }
        return identity as! SecIdentity
    }

    func start() throws {
        guard let identity = sec_identity_create(try Self.identity()) else {
            throw TestError("no sec_identity for the test identity")
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.locked { self.connections[ObjectIdentifier(connection)] = connection }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: (any Error)?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw TestError("TLS listener did not start") }
        if let failure { throw failure }
        guard let port = listener.port?.rawValue else { throw TestError("TLS listener has no port") }
        locked {
            bound = port
            self.listener = listener
        }
    }

    func stop() {
        let (listener, connections) = locked {
            defer {
                self.listener = nil
                self.connections = [:]
            }
            return (self.listener, Array(self.connections.values))
        }
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func finish(_ connection: NWConnection) {
        locked { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
        connection.cancel()
    }

    /// Reads one request head (the TLS handshake comes first, so a client that refused the certificate sends none)
    /// and answers it.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let target = head.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first
                let path = String(target?.split(separator: "?").first ?? "/")
                self.locked { self.paths.append(path) }
                let response = self.handler(path)
                connection.send(
                    content: Self.encode(response), completion: .contentProcessed { _ in self.finish(connection) })
                return
            }
            if complete || error != nil { return self.finish(connection) }
            self.receive(connection, buffer: buffer)
        }
    }

    private static func encode(_ response: FixtureServer.Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
        for line in response.headers { head += line + "\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
