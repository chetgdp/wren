import Foundation

enum DaemonError: Error, CustomStringConvertible {
    case notRunning(host: String)
    case http(status: Int, message: String?)
    case invalidResponse

    var description: String {
        switch self {
        case .notRunning(let host):
            return "daemon not running on \(host) - is it started?"
        case .http(let status, let message):
            return "daemon returned \(status): \(message ?? "no error detail")"
        case .invalidResponse:
            return "daemon sent a non-HTTP response"
        }
    }
}

/// HTTP client for the TTS daemon. Request construction is pure (no
/// network) so the paths, bodies, and headers are unit-testable; only
/// send() touches the wire.
struct DaemonClient {
    static let defaultHost = "127.0.0.1:8765"

    let host: String
    let token: String?

    /// Flag beats env beats the loopback default. Environment is a
    /// parameter so tests don't have to mutate the process environment.
    static func resolveHost(
        flag: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let flag, !flag.isEmpty { return flag }
        if let env = environment["WREN_HOST"], !env.isEmpty { return env }
        return defaultHost
    }

    static func resolveToken(
        flag: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let flag, !flag.isEmpty { return flag }
        if let env = environment["WREN_TOKEN"], !env.isEmpty { return env }
        return nil
    }

    // The daemon writes snake_case JSON; the coders bridge it to the
    // camelCase model structs.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func request(path: String) throws -> URLRequest {
        guard let url = URL(string: "http://\(host)\(path)") else {
            throw ValidationFailure("invalid host: \(host)")
        }
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func postRequest(path: String, body: some Encodable) throws -> URLRequest {
        var request = try request(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        return request
    }

    func get<R: Decodable>(_ path: String) async throws -> R {
        try await send(request(path: path))
    }

    func post<R: Decodable>(_ path: String, body: some Encodable) async throws -> R {
        try await send(postRequest(path: path, body: body))
    }

    /// Empty-body POST (stop/pause/resume). The daemon parses the body as
    /// JSON when present, so "{}" keeps the request unambiguous.
    func post<R: Decodable>(_ path: String) async throws -> R {
        var request = try request(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        return try await send(request)
    }

    func send<R: Decodable>(_ request: URLRequest) async throws -> R {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError
            where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw DaemonError.notRunning(host: host)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DaemonError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // The daemon's error bodies are {"error": "..."}: surface the
            // message instead of a bare status code when it parses.
            let message = try? Self.decoder.decode(ErrorBody.self, from: data).error
            throw DaemonError.http(status: http.statusCode, message: message)
        }
        return try Self.decoder.decode(R.self, from: data)
    }
}
