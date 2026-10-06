import Foundation

enum DaemonError: Error, CustomStringConvertible, Equatable {
    case notRunning(host: String)
    case http(status: Int, message: String?)
    case invalidResponse
    case management(status: Int, error: ManagementErrorDetail)

    var description: String {
        switch self {
        case .notRunning(let host):
            return "server not reachable at \(host)"
        case .http(let status, let message):
            return "server returned \(status): \(message ?? "no detail")"
        case .invalidResponse:
            return "server sent a non-HTTP response"
        case .management(let status, let error):
            return "server returned \(status) \(error.code): "
                + error.message
        }
    }
}

/// HTTP client for the synthesis server (local://contract.md routes).
struct DaemonClient: Sendable {
    typealias Transport =
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let host: String
    let transport: Transport

    init(
        host: String,
        transport: @escaping Transport = {
            try await URLSession.shared.data(for: $0)
        }
    ) {
        self.host = host
        self.transport = transport
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: Request building

    func request(path: String, method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: "http://\(host)\(path)") else {
            throw ValidationFailure("invalid host: \(host)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    func jsonRequest(
        path: String,
        method: String,
        body: some Encodable
    ) throws -> URLRequest {
        var req = try request(path: path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(body)
        return req
    }

    /// Voice ids land in a path segment; encode anything outside the
    /// unreserved set so a hostile id cannot reroute the request.
    static func pathSegment(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? raw
    }

    func speakRequest(_ body: SpeakRequest) throws -> URLRequest {
        try jsonRequest(path: "/speak", method: "POST", body: body)
    }

    func stopRequest(channel: String?, all: Bool) throws -> URLRequest {
        try jsonRequest(
            path: "/stop",
            method: "POST",
            body: StopRequest(channel: channel, all: all ? true : nil)
        )
    }

    func pauseRequest(_ paused: Bool, channel: String?) throws
        -> URLRequest {
        try jsonRequest(
            path: paused ? "/pause" : "/resume",
            method: "POST",
            body: PauseRequest(channel: channel)
        )
    }

    func claimRequest(channel: String, label: String?) throws -> URLRequest {
        try jsonRequest(
            path: "/clients/active",
            method: "POST",
            body: ActiveClientRequest(channel: channel, label: label)
        )
    }

    func activateVoiceRequest(_ voice: String) throws -> URLRequest {
        try jsonRequest(
            path: "/voice",
            method: "PUT",
            body: ActivateVoiceRequest(voice: voice)
        )
    }

    func settingsRequest(_ update: SettingsUpdateRequest) throws
        -> URLRequest {
        try jsonRequest(path: "/settings", method: "PATCH", body: update)
    }

    func renameVoiceRequest(id: String, displayName: String) throws
        -> URLRequest {
        try jsonRequest(
            path: "/voices/\(Self.pathSegment(id))",
            method: "PATCH",
            body: RenameVoiceRequest(displayName: displayName)
        )
    }

    func deleteVoiceRequest(id: String) throws -> URLRequest {
        try request(
            path: "/voices/\(Self.pathSegment(id))",
            method: "DELETE"
        )
    }

    func addVoiceRequest(
        id: String,
        name: String,
        audio: Data,
        transcript: String,
        boundary: String = "wren-\(UUID().uuidString)"
    ) throws -> URLRequest {
        var req = try request(path: "/voices", method: "POST")
        req.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        req.httpBody = Multipart.body(
            boundary: boundary,
            fields: [
                ("id", id),
                ("display_name", name),
                ("transcript", transcript),
            ],
            file: (
                name: "audio",
                filename: "reference.wav",
                type: "audio/wav",
                data: audio
            )
        )
        return req
    }

    // MARK: Transport

    func send<R: Decodable>(_ request: URLRequest) async throws -> R {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is URLError {
            // Connection refused, DNS, timeout: the actionable fact for a
            // user is which endpoint failed, not the URLError code.
            throw DaemonError.notRunning(host: host)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DaemonError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? Self.decoder.decode(
                ManagementErrorEnvelope.self,
                from: data
            )
            if let envelope {
                throw DaemonError.management(
                    status: http.statusCode,
                    error: envelope.error
                )
            }
            throw DaemonError.http(
                status: http.statusCode,
                message: String(data: data, encoding: .utf8)
            )
        }
        return try Self.decoder.decode(R.self, from: data)
    }

    // MARK: Routes

    func state() async throws -> DaemonStateResponse {
        try await send(request(path: "/state"))
    }

    func health() async throws -> HealthResponse {
        try await send(request(path: "/health"))
    }

    func voices() async throws -> VoiceListResponse {
        try await send(request(path: "/voices"))
    }

    func activateVoice(_ voice: String) async throws -> DaemonStateResponse {
        try await send(activateVoiceRequest(voice))
    }

    func updateSettings(
        _ update: SettingsUpdateRequest
    ) async throws -> DaemonStateResponse {
        try await send(settingsRequest(update))
    }

    func claimActive(
        channel: String,
        label: String? = nil
    ) async throws -> ActiveClientResponse {
        try await send(claimRequest(channel: channel, label: label))
    }

    func speak(_ body: SpeakRequest) async throws -> SpeakResponse {
        try await send(speakRequest(body))
    }

    func stop(
        channel: String? = nil,
        all: Bool = false
    ) async throws -> StopResponse {
        try await send(stopRequest(channel: channel, all: all))
    }

    func pause(channel: String? = nil) async throws -> PauseResponse {
        try await send(pauseRequest(true, channel: channel))
    }

    func resume(channel: String? = nil) async throws -> PauseResponse {
        try await send(pauseRequest(false, channel: channel))
    }

    func renameVoice(
        id: String,
        displayName: String
    ) async throws -> VoiceProfile {
        try await send(renameVoiceRequest(id: id, displayName: displayName))
    }

    func deleteVoice(id: String) async throws -> StopResponse {
        try await send(deleteVoiceRequest(id: id))
    }

    func addVoice(
        id: String,
        name: String,
        audioURL: URL,
        transcript: String
    ) async throws -> VoiceProfile {
        let audio = try Data(contentsOf: audioURL)
        return try await send(addVoiceRequest(
            id: id,
            name: name,
            audio: audio,
            transcript: transcript
        ))
    }
}

enum Multipart {
    static func body(
        boundary: String,
        fields: [(String, String)],
        file: (name: String, filename: String, type: String, data: Data)
    ) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(escape(name))\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line(
            "Content-Disposition: form-data; name=\"\(escape(file.name))\"; "
                + "filename=\"\(escape(file.filename))\""
        )
        line("Content-Type: \(file.type)")
        line("")
        body.append(file.data)
        line("")
        line("--\(boundary)--")
        return body
    }

    /// Quotes and line breaks would end the header parameter early.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}
