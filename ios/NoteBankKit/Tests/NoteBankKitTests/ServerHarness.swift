import Foundation
import Network
import Synchronization

enum HarnessError: Error {
    case postgres, serverExited, pushRefused(String)
}

private let adminURL = ProcessInfo.processInfo.environment["NOTEBANK_TEST_ADMIN_URL"] ?? "postgres:///postgres"

@discardableResult
private func run(_ tool: String, _ arguments: [String], in directory: URL? = nil, quietly: Bool = true) throws -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = [tool] + arguments
    process.currentDirectoryURL = directory
    if quietly { process.standardOutput = FileHandle.nullDevice }
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

private let serverBinary: URL = {
    var repo = URL(filePath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let binary = FileManager.default.temporaryDirectory.appending(path: "notebank-ios-test-server/notebank-server")
    guard (try? run("go", ["build", "-o", binary.path, "./cmd/notebank-server"], in: repo.appending(path: "server"), quietly: false)) == true else {
        preconditionFailure("go build of the Server failed (is Go installed?)")
    }
    return binary
}()

private func loopback(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    return address
}

private func freePort() -> UInt16 {
    let socket = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(socket) }
    var address = loopback(port: 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = bind(socket, $0, length)
            _ = getsockname(socket, $0, &length)
        }
    }
    return UInt16(bigEndian: address.sin_port)
}

private func accepts(port: UInt16) -> Bool {
    let socket = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(socket) }
    var address = loopback(port: port)
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
}

final class TestServer {
    let url: String
    let secret = "test-secret-that-is-at-least-32-characters"
    let port: UInt16
    private let databaseName = "notebank_ios_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let attachments = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    private var process: Process?

    init() throws {
        guard try run("psql", [adminURL, "-v", "ON_ERROR_STOP=1", "-qc", "CREATE DATABASE \(databaseName)"]) else {
            throw HarnessError.postgres
        }
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        port = freePort()
        url = "http://127.0.0.1:\(port)"
    }

    func start() async throws {
        var database = URLComponents(string: adminURL)!
        database.path = "/" + databaseName
        let process = Process()
        process.executableURL = serverBinary
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NOTEBANK_DATABASE_URL": database.string!,
            "NOTEBANK_SECRET": secret,
            "NOTEBANK_LISTEN_ADDR": "127.0.0.1:\(port)",
            "NOTEBANK_ATTACHMENT_DIR": attachments.path,
        ]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        // The Server migrates before it listens, so an open port means it's ready.
        for _ in 0..<100 {
            if accepts(port: port) { return }
            guard process.isRunning else { throw HarnessError.serverExited }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.serverExited
    }

    func push(device: String, ops: [[String: String]]) async throws {
        var request = URLRequest(url: URL(string: url + "/sync/push")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["device_id": device, "ops": ops])
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        let results = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]
        guard let results, results.count == ops.count, results.allSatisfy({ $0["status"] as? String == "accepted" }) else {
            throw HarnessError.pushRefused(String(decoding: data, as: UTF8.self))
        }
    }

    deinit {
        if let process {
            kill(process.processIdentifier, SIGKILL)
            // Foundation's run-loop wait can hang after an externally signalled exit.
            while waitpid(process.processIdentifier, nil, 0) == -1 && errno == EINTR {}
        }
        _ = try? run("psql", [adminURL, "-qc", "DROP DATABASE IF EXISTS \(databaseName) WITH (FORCE)"])
        try? FileManager.default.removeItem(at: attachments)
    }
}

final class FakeServer: Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeServer")
    private let handler: @Sendable (Request) -> Response
    private let hits = Mutex<[String: Int]>([:])
    private let ready = Mutex(false)

    init(_ handler: @escaping @Sendable (Request) -> Response) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receive(connection, buffer: Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.withLock { $0 = true } }
        }
        listener.start(queue: queue)
        for _ in 0..<200 where !ready.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        guard ready.withLock({ $0 }) else { throw HarnessError.serverExited }
    }

    deinit { listener.cancel() }

    var url: String { "http://127.0.0.1:\(listener.port!.rawValue)" }

    func requests(to path: String) -> Int { hits.withLock { $0[path] ?? 0 } }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            // Anything starting below "A" (a TLS handshake) isn't HTTP; hanging up fails the client at once.
            if let request = Self.parse(buffer) {
                respond(to: request, on: connection)
            } else if error == nil && !isComplete && buffer.first.map({ $0 >= 0x41 }) != false {
                receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let length = lines.lazy.compactMap { $0.lowercased().hasPrefix("content-length:") ? Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil }.first ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        let parts = lines[0].split(separator: " ")
        let target = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 { headers[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        return Request(method: String(parts[0]), path: String(target[0]), query: target.count > 1 ? String(target[1]) : "", headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(to request: Request, on connection: NWConnection) {
        hits.withLock { $0[request.path, default: 0] += 1 }
        let response = handler(request)
        var head = "HTTP/1.1 \(response.status) X\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
