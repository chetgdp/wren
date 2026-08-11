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

/// Partial POST /config body: exactly one (or a few) of the daemon's
/// settable keys. Typed fields instead of a string dictionary so speed/fx/
/// port go over the wire as JSON numbers and booleans, which the daemon
/// validates strictly.
struct ConfigUpdate: Encodable {
    var voice: String?
    var voicesDir: String?
    var speed: Double?
    var fx: Bool?
    var port: Int?
    var backend: String?

    /// The keys `wren config <key> <value>` accepts, with per-key parsing.
    static func parsing(key: String, value: String) throws -> ConfigUpdate {
        switch key {
        case "speed":
            guard let speed = Double(value) else {
                throw ValidationFailure("speed must be a number, got '\(value)'")
            }
            return ConfigUpdate(speed: speed)
        case "fx":
            guard let fx = Bool(value) else {
                throw ValidationFailure("fx must be true or false, got '\(value)'")
            }
            return ConfigUpdate(fx: fx)
        case "port":
            guard let port = Int(value) else {
                throw ValidationFailure("port must be an integer, got '\(value)'")
            }
            return ConfigUpdate(port: port)
        case "voice":
            return ConfigUpdate(voice: value)
        case "voices_dir":
            return ConfigUpdate(voicesDir: value)
        case "backend":
            return ConfigUpdate(backend: value)
        default:
            throw ValidationFailure(
                "unknown config key '\(key)' (known: voice, voices_dir, speed, fx, port, backend)")
        }
    }
}

struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// GET and POST /config both return this shape; persisted/persistError only
/// appear on POST responses.
struct ConfigPayload: Decodable {
    var voice: String?
    var voicesDir: String?
    var speed: Double
    var fx: Bool
    var port: Int
    var backend: String
    var restartRequired: Bool
    var persisted: Bool?
    var persistError: String?
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
