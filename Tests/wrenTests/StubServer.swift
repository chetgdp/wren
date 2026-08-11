import Foundation
import Network

/// Minimal HTTP/1.1 server on an ephemeral loopback port for round-trip
/// tests. Records every request it parses; the response comes from the
/// injected closure. Never binds 8765: that port belongs to the user's
/// live daemon.
final class StubServer {
    struct Request {
        var method: String
        var path: String
        var headers: [String: String]  // lowercased names
        var body: Data
    }

    /// Connection handling lives here, not on StubServer: NWListener needs
    /// its newConnectionHandler set before start(), and a closure capturing
    /// StubServer's self cannot exist until init finishes (port is a let
    /// assigned after the listener is ready).
    private final class Core: @unchecked Sendable {
        let respond: (Request) -> (status: Int, body: String)
        let queue = DispatchQueue(label: "wren.stub-server")
        private let lock = NSLock()
        private var recorded: [Request] = []

        init(respond: @escaping (Request) -> (status: Int, body: String)) {
            self.respond = respond
        }

        var requests: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }

        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                guard error == nil else {
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = StubServer.parse(buffer) {
                    self.lock.lock()
                    self.recorded.append(request)
                    self.lock.unlock()
                    StubServer.send(self.respond(request), over: connection)
                } else if isComplete {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private let listener: NWListener
    private let core: Core

    let port: UInt16

    var requests: [Request] { core.requests }

    init(respond: @escaping (Request) -> (status: Int, body: String)) throws {
        let core = Core(respond: respond)
        self.core = core
        listener = try NWListener(using: .tcp, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            core.handle(connection)
        }
        listener.start(queue: core.queue)
        ready.wait()
        guard let port = listener.port?.rawValue, port != 0 else {
            throw NSError(domain: "StubServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener failed to bind"])
        }
        self.port = port
    }

    func stop() {
        listener.cancel()
    }

    /// nil until the headers and the full Content-Length body have arrived.
    fileprivate static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(body.prefix(length))
        )
    }

    fileprivate static func send(_ response: (status: Int, body: String), over connection: NWConnection) {
        let body = Data(response.body.utf8)
        let head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + body,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
