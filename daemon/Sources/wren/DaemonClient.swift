import Foundation

enum DaemonError: Error, CustomStringConvertible {
    // Legacy playback/CLI errors remain for unversioned endpoint callers.
    case notRunning(host: String)
    case http(status: Int, message: String?)
    case invalidResponse

    case authorization(status: Int, error: ManagementErrorDetail?)
    case originAccess(status: Int, error: ManagementErrorDetail?)
    case identity(service: String)
    case identityMetadata(description: String)
    case compatibility(
        protocolVersion: Int,
        missingCapabilities: [DaemonCapability]
    )
    case management(status: Int, error: ManagementErrorDetail)
    case transportRefused(host: String)
    case transport(description: String)
    case ambiguousSubmittedMutation(
        requestID: String,
        description: String
    )
    case invalidDecoding(description: String)

    var description: String {
        switch self {
        case .notRunning(let host):
            return "daemon not running on \(host) - is it started?"
        case .http(let status, let message):
            return "daemon returned \(status): \(message ?? "no error detail")"
        case .invalidResponse:
            return "daemon sent a non-HTTP response"
        case .authorization(_, let error):
            return error?.message ?? "daemon authorization failed"
        case .originAccess(_, let error):
            return error?.message ?? "daemon rejected this request origin"
        case .identity(let service):
            return "endpoint is \(service), not wren"
        case .identityMetadata(let description):
            return "endpoint returned invalid Wren identity: \(description)"
        case .compatibility(let version, let missing):
            let capabilities = missing.map(\.rawValue).joined(separator: ", ")
            if capabilities.isEmpty {
                return "daemon protocol \(version) is incompatible"
            }
            return "daemon protocol \(version) lacks \(capabilities)"
        case .management(let status, let error):
            return "daemon returned \(status) \(error.code): \(error.message)"
        case .transportRefused(let host):
            return "connection to daemon at \(host) was refused"
        case .transport(let description):
            return "daemon transport failed: \(description)"
        case .ambiguousSubmittedMutation(let requestID, let description):
            return "mutation \(requestID) may have completed: \(description)"
        case .invalidDecoding(let description):
            return "daemon response could not be decoded: \(description)"
        }
    }
}

/// HTTP client for the TTS daemon. Request construction is pure (no
/// network) so the paths, bodies, and headers are unit-testable; only
/// send() touches the wire.
struct DaemonClient: Sendable {
    typealias Transport = @Sendable (
        URLRequest
    ) async throws -> (Data, URLResponse)

    static let defaultHost = "127.0.0.1:8765"

    let host: String
    let token: String?
    private let transport: Transport

    init(
        host: String,
        token: String?,
        transport: @escaping Transport = {
            try await URLSession.shared.data(for: $0)
        }
    ) {
        self.host = host
        self.token = token
        self.transport = transport
    }

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
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization")
        }
        // Native clients deliberately omit Origin. The daemon still applies
        // its Origin policy if a caller explicitly sends one.
        return request
    }

    func postRequest(
        path: String,
        body: some Encodable
    ) throws -> URLRequest {
        var request = try request(path: path)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        return request
    }

    func mutationRequest(
        method: String,
        path: String,
        requestID: String,
        body: some Encodable
    ) throws -> URLRequest {
        try makeMutationRequest(
            method: method,
            path: path,
            requestID: requestID,
            body: Self.encoder.encode(body))
    }

    func mutationRequest(
        method: String,
        path: String,
        requestID: String
    ) throws -> URLRequest {
        try makeMutationRequest(
            method: method,
            path: path,
            requestID: requestID,
            body: nil)
    }

    private func makeMutationRequest(
        method: String,
        path: String,
        requestID: String,
        body: Data?
    ) throws -> URLRequest {
        let methods = ["POST", "PATCH", "DELETE"]
        guard methods.contains(method) else {
            throw ValidationFailure(
                "management mutation method must be POST, PATCH, or DELETE")
        }
        guard !requestID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationFailure(
                "management mutations require a nonempty request ID")
        }

        var request = try request(path: path)
        request.httpMethod = method
        request.setValue(
            requestID,
            forHTTPHeaderField: "Idempotency-Key")
        if let body {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    func get<R: Decodable>(_ path: String) async throws -> R {
        try await send(request(path: path))
    }

    func post<R: Decodable>(
        _ path: String,
        body: some Encodable
    ) async throws -> R {
        try await send(postRequest(path: path, body: body))
    }

    /// Empty-body POST (stop/pause/resume). The daemon parses the body as
    /// JSON when present, so "{}" keeps the request unambiguous.
    func post<R: Decodable>(_ path: String) async throws -> R {
        var request = try request(path: path)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        return try await send(request)
    }

    func health() async throws -> HealthResponse {
        try await get("/health")
    }

    func pause() async throws -> PauseResponse {
        try await post("/pause")
    }

    func resume() async throws -> PauseResponse {
        try await post("/resume")
    }

    func stopSpeaking() async throws -> StopResponse {
        try await post("/stop")
    }

    func meta() async throws -> MetaResponse {
        try await sendManagement(request(path: "/meta"))
    }

    static func validateIdentity(
        _ meta: MetaResponse,
        requiredCapabilities: Set<DaemonCapability> = []
    ) throws {
        guard meta.service == "wren" else {
            throw DaemonError.identity(service: meta.service)
        }
        guard !meta.instanceID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw DaemonError.identityMetadata(
                description: "instance_id must not be empty")
        }
        guard !meta.startedAt.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw DaemonError.identityMetadata(
                description: "started_at must not be empty")
        }
        let available = Set(meta.capabilities)
        let missing = requiredCapabilities.subtracting(available)
            .sorted { $0.rawValue < $1.rawValue }
        guard meta.protocolVersion == 2, missing.isEmpty else {
            throw DaemonError.compatibility(
                protocolVersion: meta.protocolVersion,
                missingCapabilities: missing)
        }
    }

    func state() async throws -> DaemonStateResponse {
        try await sendManagement(request(path: "/state"))
    }

    func voices() async throws -> VoiceListResponse {
        try await sendManagement(request(path: "/voices"))
    }

    func operation(requestID: String) async throws -> OperationResponse {
        let component = try Self.pathComponent(
            requestID,
            name: "operation request ID")
        return try await sendManagement(
            request(path: "/operations/\(component)"))
    }

    func postMutation<R: Decodable>(
        _ path: String,
        requestID: String,
        body: some Encodable
    ) async throws -> R {
        let request = try mutationRequest(
            method: "POST",
            path: path,
            requestID: requestID,
            body: body)
        return try await sendManagement(
            request,
            submittedMutationID: requestID)
    }

    func patchMutation<R: Decodable>(
        _ path: String,
        requestID: String,
        body: some Encodable
    ) async throws -> R {
        let request = try mutationRequest(
            method: "PATCH",
            path: path,
            requestID: requestID,
            body: body)
        return try await sendManagement(
            request,
            submittedMutationID: requestID)
    }

    func deleteMutation<R: Decodable>(
        _ path: String,
        requestID: String
    ) async throws -> R {
        let request = try mutationRequest(
            method: "DELETE",
            path: path,
            requestID: requestID)
        return try await sendManagement(
            request,
            submittedMutationID: requestID)
    }

    func activateVoice(
        _ voice: String,
        requestID: String
    ) async throws -> OperationResponse {
        try await postMutation(
            "/voices/activate",
            requestID: requestID,
            body: ActivateVoiceRequest(voice: voice))
    }

    func importVoice(
        _ importRequest: ImportVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse {
        try await postMutation(
            "/voices/import",
            requestID: requestID,
            body: importRequest)
    }

    func updateVoice(
        id: String,
        update: UpdateVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse {
        let component = try Self.pathComponent(id, name: "voice ID")
        return try await patchMutation(
            "/voices/\(component)",
            requestID: requestID,
            body: update)
    }

    func deleteVoice(
        id: String,
        requestID: String
    ) async throws -> OperationResponse {
        let component = try Self.pathComponent(id, name: "voice ID")
        return try await deleteMutation(
            "/voices/\(component)",
            requestID: requestID)
    }

    func updateSettings(
        _ update: SettingsUpdateRequest,
        requestID: String
    ) async throws -> DaemonStateResponse {
        try await patchMutation(
            "/settings",
            requestID: requestID,
            body: update)
    }

    func send<R: Decodable>(_ request: URLRequest) async throws -> R {
        try await send(
            request,
            management: false,
            submittedMutationID: nil)
    }

    private func sendManagement<R: Decodable>(
        _ request: URLRequest,
        submittedMutationID: String? = nil
    ) async throws -> R {
        try await send(
            request,
            management: true,
            submittedMutationID: submittedMutationID)
    }

    private func send<R: Decodable>(
        _ request: URLRequest,
        management: Bool,
        submittedMutationID: String?
    ) async throws -> R {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError
            where error.code == .cannotConnectToHost
                || error.code == .cannotFindHost {
            if management {
                throw DaemonError.transportRefused(host: host)
            }
            throw DaemonError.notRunning(host: host)
        } catch {
            if let requestID = submittedMutationID {
                throw DaemonError.ambiguousSubmittedMutation(
                    requestID: requestID,
                    description: error.localizedDescription)
            }
            throw DaemonError.transport(
                description: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            if let requestID = submittedMutationID {
                throw DaemonError.ambiguousSubmittedMutation(
                    requestID: requestID,
                    description: "daemon sent a non-HTTP response")
            }
            throw DaemonError.invalidResponse
        }
        if management, http.url != request.url {
            let description = "management request redirected away from "
                + "the configured endpoint"
            if let requestID = submittedMutationID {
                throw DaemonError.ambiguousSubmittedMutation(
                    requestID: requestID,
                    description: description)
            }
            throw DaemonError.transport(description: description)
        }
        guard (200..<300).contains(http.statusCode) else {
            try throwHTTPError(
                status: http.statusCode,
                data: data,
                management: management)
        }
        do {
            return try Self.decoder.decode(R.self, from: data)
        } catch {
            let description = error.localizedDescription
            if let requestID = submittedMutationID {
                throw DaemonError.ambiguousSubmittedMutation(
                    requestID: requestID,
                    description: "daemon returned an invalid success body: "
                        + description)
            }
            throw DaemonError.invalidDecoding(description: description)
        }
    }

    private func throwHTTPError(
        status: Int,
        data: Data,
        management: Bool
    ) throws -> Never {
        let structured = try? Self.decoder.decode(
            ManagementErrorEnvelope.self,
            from: data).error
        if status == 401 {
            throw DaemonError.authorization(
                status: status,
                error: structured)
        }
        if status == 403 {
            throw DaemonError.originAccess(
                status: status,
                error: structured)
        }
        if let structured {
            throw DaemonError.management(
                status: status,
                error: structured)
        }

        let message = try? Self.decoder.decode(
            ErrorBody.self,
            from: data).error
        if management {
            let error = ManagementErrorDetail(
                code: "invalid_error_response",
                message: message ?? "daemon returned HTTP \(status)",
                detail: nil,
                recoverable: nil)
            throw DaemonError.management(status: status, error: error)
        }
        throw DaemonError.http(status: status, message: message)
    }

    private static func pathComponent(
        _ value: String,
        name: String
    ) throws -> String {
        guard !value.isEmpty else {
            throw ValidationFailure("\(name) must not be empty")
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~"))
        guard let component = value.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) else {
            throw ValidationFailure("invalid \(name): \(value)")
        }
        return component
    }
}
