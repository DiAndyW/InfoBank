import Foundation
import Network
import Synchronization

enum HarnessError: Error {
    case postgres, serverExited, pushRefused(String), notReady(log: String), foreignServer(port: UInt16, status: Int)
}

private let adminURL = ProcessInfo.processInfo.environment["NOTEBANK_TEST_ADMIN_URL"] ?? "postgres:///postgres"

private func tool(_ name: String, _ arguments: [String], in directory: URL? = nil, quietly: Bool = true) -> Process {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = [name] + arguments
    process.currentDirectoryURL = directory
    if quietly { process.standardOutput = FileHandle.nullDevice }
    return process
}

// Never wait on a subprocess synchronously: tests share the main actor and the cooperative pool.
private func run(_ process: Process) async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
}

private let serverBinary = Task<URL, Never> {
    var repo = URL(filePath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let binary = FileManager.default.temporaryDirectory.appending(path: "notebank-ios-test-server/notebank-server")
    guard (try? await run(tool("go", ["build", "-o", binary.path, "./cmd/notebank-server"], in: repo.appending(path: "server"), quietly: false))) == true else {
        preconditionFailure("go build of the Server failed (is Go installed?)")
    }
    return binary
}

private func loopback(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    return address
}

// Bound but not listening: other tests can't take the port, and connections are refused until `start`.
private func reservePort() throws -> (socket: Int32, port: UInt16) {
    let socket = socket(AF_INET, SOCK_STREAM, 0)
    var address = loopback(port: 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
        }
    }
    guard bound else {
        close(socket)
        throw POSIXError(.EADDRNOTAVAIL)
    }
    return (socket, UInt16(bigEndian: address.sin_port))
}

final class TestServer {
    let url: String
    let secret = "test-secret-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let port: UInt16
    private var reserved: Int32?
    private let log = testDirectory.appending(path: "notebank-test-server-\(UUID().uuidString).log")
    private let databaseName = "notebank_ios_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let attachments = testDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    private var process: Process?
    private var created = false

    init() throws {
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        (reserved, port) = try reservePort()
        url = "http://127.0.0.1:\(port)"
    }

    func start() async throws {
        guard try await run(tool("psql", [adminURL, "-v", "ON_ERROR_STOP=1", "-qc", "CREATE DATABASE \(databaseName)"])) else {
            throw HarnessError.postgres
        }
        created = true
        if let reserved { close(reserved) }
        reserved = nil
        var database = URLComponents(string: adminURL)!
        database.path = "/" + databaseName
        let process = Process()
        process.executableURL = await serverBinary.value
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NOTEBANK_DATABASE_URL": database.string!,
            "NOTEBANK_SECRET": secret,
            "NOTEBANK_LISTEN_ADDR": "127.0.0.1:\(port)",
            "NOTEBANK_ATTACHMENT_DIR": attachments.path,
        ]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        try process.run()
        self.process = process
        // Only this Server accepts this secret, so a 204 proves the port is ours.
        var request = URLRequest(url: URL(string: url + "/auth/check")!, timeoutInterval: 2)
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            guard process.isRunning else { break }
            if let (_, response) = try? await session.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode {
                if status == 204 { return }
                throw HarnessError.foreignServer(port: port, status: status)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HarnessError.notReady(log: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
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
        if let reserved { close(reserved) }
        if created { try? tool("psql", [adminURL, "-qc", "DROP DATABASE \(databaseName) WITH (FORCE)"]).run() }
        try? FileManager.default.removeItem(at: attachments)
        try? FileManager.default.removeItem(at: log)
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
