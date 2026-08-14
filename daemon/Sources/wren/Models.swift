import Foundation

/// Wire types for tts/serve.py. The daemon speaks snake_case JSON, so both
/// coders use the snake-case key strategies and these structs stay camelCase.

struct SpeakRequest: Encodable {
    var text: String
    // Synthesized Encodable skips nil optionals, so absent flags stay off
    // the wire and the daemon's defaults apply.
    var append: Bool?
    var raw: Bool?
    var speed: Double?
}

struct SpeakResponse: Decodable {
    var queued: Int
}

struct StopResponse: Decodable {
    var ok: Bool
}

struct PauseResponse: Decodable {
    var ok: Bool
    var paused: Bool
}


struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}


struct HealthResponse: Decodable {
    var ok: Bool
    var ready: Bool
    var model: String
    var playback: String
    var pending: Int
    var speaking: Bool
    var paused: Bool
    var block: [Int]?
    var speed: Double?
    var channels: [String: ChannelHealth]?
}

struct ChannelHealth: Decodable {
    var pending: Int
    var speaking: Bool
    var paused: Bool
    var block: [Int]?
    var active: Bool
}

struct ErrorBody: Decodable {
    var error: String
}

// MARK: - Management API v2

/// A forward-compatible management capability. Unknown values are preserved
/// so a newer daemon can still complete the identity handshake.
struct DaemonCapability: Codable, Hashable, RawRepresentable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let stateV2 = Self(rawValue: "state-v2")
    static let voiceList = Self(rawValue: "voice-list")
    static let voiceActivate = Self(rawValue: "voice-activate")
    static let settingsV2 = Self(rawValue: "settings-v2")
    static let stagedImport = Self(rawValue: "staged-import")
    static let segmentPlayer = Self(rawValue: "segment-player")
}
struct MetaResponse: Decodable, Equatable, Sendable {
    var service: String
    var protocolVersion: Int
    var instanceID: String
    var startedAt: String
    var capabilities: [DaemonCapability]

    private enum CodingKeys: String, CodingKey {
        case service
        case protocolVersion
        // JSONDecoder normalizes the wire key `instance_id` to `instanceId`.
        case instanceID = "instanceId"
        case startedAt
        case capabilities
    }
}

enum DaemonLifecyclePhase: String, Codable, Equatable, Sendable {
    case starting
    case loading
    case ready
    case degraded
    case failed
}

struct DaemonLifecycle: Codable, Equatable, Sendable {
    var phase: DaemonLifecyclePhase
    var message: String?
}

struct SynthesisState: Codable, Equatable, Sendable {
    var ready: Bool
    var activeVoice: String?
    var effects: Bool
    var defaultSynthesisRate: Double
    var backend: String
    var model: String
    var host: String?
    var port: Int?
    var voicesDirectory: String?

    private enum CodingKeys: String, CodingKey {
        case ready
        case activeVoice
        case effects
        case defaultSynthesisRate
        case backend
        case model
        case host
        case port
        // JSONDecoder normalizes the wire key `voices_dir` to `voicesDir`.
        case voicesDirectory = "voicesDir"
    }
}

struct PlaybackState: Codable, Equatable, Sendable {
    var pending: Int
    var speaking: Bool
    var paused: Bool
}

struct ManagementErrorDetail: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var detail: JSONValue?
    var recoverable: Bool?

    init(
        code: String,
        message: String,
        detail: JSONValue?,
        recoverable: Bool?
    ) {
        self.code = code
        self.message = message
        self.detail = detail
        self.recoverable = recoverable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        detail = container.contains(.detail)
            ? try container.decode(JSONValue.self, forKey: .detail)
            : nil
        recoverable = try container.decodeIfPresent(
            Bool.self,
            forKey: .recoverable)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        if let detail {
            try container.encode(detail, forKey: .detail)
        }
        try container.encodeIfPresent(recoverable, forKey: .recoverable)
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case detail
        case recoverable
    }
}

struct ManagementErrorEnvelope: Decodable, Equatable, Sendable {
    var error: ManagementErrorDetail
}

/// JSON returned by a completed operation. Keeping the value typed avoids
/// lossy `[String: Any]` conversion while permitting mutation-specific results.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(
                try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

struct OperationPhase: Codable, Hashable, RawRepresentable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let pending = Self(rawValue: "pending")
    static let preparing = Self(rawValue: "preparing")
    static let committing = Self(rawValue: "committing")
    static let succeeded = Self(rawValue: "succeeded")
    static let failed = Self(rawValue: "failed")

    var isTerminal: Bool {
        self == .succeeded || self == .failed
    }
}

struct OperationResponse: Codable, Equatable, Sendable {
    var id: String
    var kind: String
    var phase: OperationPhase
    var target: String?
    var progress: Double?
    var error: ManagementErrorDetail?
    var response: JSONValue?
}

struct DaemonStateResponse: Codable, Equatable, Sendable {
    var revision: Int
    var voicesRevision: Int
    var lifecycle: DaemonLifecycle
    var synthesis: SynthesisState
    var operation: OperationResponse?
    var playback: PlaybackState
    var lastError: ManagementErrorDetail?
}

enum VoiceStatus: String, Codable, Equatable, Sendable {
    case ready
    case incomplete
    case invalid
}

struct VoiceIssue: Decodable, Equatable, Sendable {
    var code: String
    var field: String?
    var message: String
}

struct VoiceProfile: Decodable, Equatable, Sendable {
    var id: String
    var displayName: String
    var status: VoiceStatus
    var issues: [VoiceIssue]
}

struct VoiceListResponse: Decodable, Equatable, Sendable {
    var revision: Int
    var voices: [VoiceProfile]
}

struct ActivateVoiceRequest: Encodable, Equatable, Sendable {
    var voice: String
}

struct ImportVoiceRequest: Encodable, Equatable, Sendable {
    var stagingID: String
    var id: String
    var displayName: String
}

struct UpdateVoiceRequest: Encodable, Equatable, Sendable {
    var displayName: String
}

struct SettingsUpdateRequest: Encodable, Equatable, Sendable {
    var effects: Bool?
    var defaultSynthesisRate: Double?
}
