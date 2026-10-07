import Foundation

/// Wire types for tts/serve.py v3 contract.
struct SpeakRequest: Encodable {
    var text: String
    var append: Bool?
    var raw: Bool?
    var channel: String?
}

struct SpeakResponse: Decodable {
    var queued: Int
    var channel: String?
}

struct StopRequest: Encodable {
    var channel: String?
    var all: Bool?
}

struct StopResponse: Decodable {
    var ok: Bool
}

struct PauseRequest: Encodable {
    var channel: String?
}

struct PauseResponse: Decodable {
    var ok: Bool
    var paused: Bool
}

struct ActiveClientRequest: Encodable {
    var channel: String
    var label: String?
}

struct ActiveClientResponse: Decodable {
    var active: String
}

struct ClientInfo: Codable, Equatable, Sendable {
    var channel: String
    var label: String?
}

struct ChannelInfo: Codable, Equatable, Sendable {
    var label: String?
    var speaking: Bool
    var paused: Bool
    var pending: Int
    // No explicit CodingKeys: the decoder's convertFromSnakeCase rewrites
    // "last_seen" to "lastSeen" before matching, so a raw-value key of
    // "last_seen" would never match and the field would silently be nil.
    var lastSeen: Double?
}

struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct HealthResponse: Decodable {
    var ok: Bool
    var ready: Bool
    var model: String?
    var activeClient: String?
    var channels: [String: ChannelHealth]?

}

struct ChannelHealth: Decodable {
    var speaking: Bool
    var paused: Bool
    var pending: Int
    var block: [Int]?
}

struct VoiceProfile: Codable, Equatable, Sendable {
    var id: String
    var displayName: String

}

struct VoiceListResponse: Decodable, Equatable, Sendable {
    var voices: [VoiceProfile]
    var activeVoice: String?

}

struct ActivateVoiceRequest: Encodable, Equatable, Sendable {
    var voice: String
}

struct RenameVoiceRequest: Encodable, Equatable, Sendable {
    var displayName: String
}

struct SettingsUpdateRequest: Encodable, Equatable, Sendable {
    var effects: Bool?
}

struct DaemonStateResponse: Codable, Equatable, Sendable {
    var ready: Bool
    var error: String?
    var backend: String?
    var model: String?
    var activeVoice: String?
    var effects: Bool?
    var activeClient: ClientInfo?
    var channels: [String: ChannelInfo]?
    var voices: [VoiceProfile]?
}

struct ManagementErrorDetail: Codable, Equatable, Sendable {
    var code: String
    var message: String
}

struct ManagementErrorEnvelope: Decodable, Equatable, Sendable {
    var error: ManagementErrorDetail
}
