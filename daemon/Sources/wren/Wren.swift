import ArgumentParser
import Foundation

@main
struct Wren: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wren",
        abstract: "Wren speech client: menu bar app (default) and CLI.",
        subcommands: [
            RunApp.self, Say.self, Yell.self, Stop.self, Pause.self,
            Resume.self, Voices.self, Voice.self, Effects.self,
            StateCommand.self, Status.self, Doctor.self,
        ],
        defaultSubcommand: RunApp.self
    )
}

struct ClientOptions: ParsableArguments {
    @Option(name: .long, help: "Server host:port (env WREN_HOST).")
    var host: String?

    /// Flag beats env beats saved (see Endpoint).
    func client(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        saved: EndpointPersisting = SystemEndpointStore()
    ) -> DaemonClient {
        DaemonClient(
            host: Endpoint.resolveHost(
                flag: host,
                environment: environment,
                saved: saved.savedHost
            )
        )
    }
}

/// Runs one request and turns any failure into a one-line stderr message
/// and exit 1, instead of ArgumentParser's usage dump.
func request<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) throws -> T {
    do {
        return try blocking(body)
    } catch {
        FileHandle.standardError.write(Data("wren: \(error)\n".utf8))
        throw ExitCode(1)
    }
}

enum SpeakInput {
    static func resolve(
        arguments: [String],
        stdinIsTTY: @autoclosure () -> Bool = isatty(0) != 0,
        readStdin: () -> Data = {
            FileHandle.standardInput.readDataToEndOfFile()
        }
    ) throws -> String {
        if !arguments.isEmpty { return arguments.joined(separator: " ") }
        guard !stdinIsTTY() else {
            throw ValidationError("no text to speak: pass words or pipe text")
        }
        let text = String(decoding: readStdin(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ValidationError("no text to speak: stdin was empty")
        }
        return text
    }
}

struct SpeakOptions: ParsableArguments {
    @Argument(help: "Text to speak (or pipe it on stdin).")
    var text: [String] = []

    @Flag(name: .long, help: "Skip markdown stripping.")
    var raw = false

    @Option(name: .long, help: "Playback speed 0.5-3.0.")
    var speed: Double?

    func validate() throws {
        if let speed, !(0.5...3.0).contains(speed) {
            throw ValidationError("--speed must be between 0.5 and 3.0")
        }
    }

    /// No channel: the server routes CLI speech to the active Mac, which
    /// is the whole point of running `wren say` over SSH.
    func body(append: Bool) throws -> SpeakRequest {
        SpeakRequest(
            text: try SpeakInput.resolve(arguments: text),
            append: append,
            raw: raw ? true : nil,
            speed: speed,
            channel: nil
        )
    }
}

struct Say: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Queue text on the active Mac (POST /speak, append)."
    )

    @OptionGroup var speak: SpeakOptions
    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let body = try speak.body(append: true)
        let res = try request { try await client.speak(body) }
        print("queued \(res.queued) on \(res.channel ?? "active client")")
    }
}

struct Yell: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Speak now, cutting off the active Mac (POST /speak)."
    )

    @OptionGroup var speak: SpeakOptions
    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let body = try speak.body(append: false)
        let res = try request { try await client.speak(body) }
        print("queued \(res.queued) on \(res.channel ?? "active client")")
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop speech on the active Mac (POST /stop)."
    )

    @Flag(name: .long, help: "Stop every channel.")
    var all = false

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let all = all
        _ = try request { try await client.stop(all: all) }
        print(all ? "stopped all" : "stopped")
    }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pause the active Mac (POST /pause)."
    )

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let res = try request { try await client.pause() }
        print(res.paused ? "paused" : "not paused")
    }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resume the active Mac (POST /resume)."
    )

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let res = try request { try await client.resume() }
        print(res.paused ? "still paused" : "resumed")
    }
}

struct Voices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List voices; * marks the active one (GET /voices)."
    )

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let res = try request { try await client.voices() }
        for voice in res.voices {
            let mark = voice.id == res.activeVoice ? "*" : " "
            print("\(mark) \(voice.id)\t\(voice.displayName)")
        }
    }
}

struct Voice: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage voices.",
        subcommands: [
            VoiceUse.self, VoiceAdd.self, VoiceRename.self, VoiceDelete.self,
        ]
    )
}

struct VoiceUse: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Activate a voice; waits until it is loaded (PUT /voice)."
    )

    @Argument(help: "Voice id.")
    var voice: String

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let voice = voice
        let state = try request { try await client.activateVoice(voice) }
        print("voice \(state.activeVoice ?? voice)")
    }
}

struct VoiceAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Upload a voice from a WAV clip (POST /voices)."
    )

    @Argument(help: "Voice id ([a-z0-9_-]).")
    var id: String

    @Option(name: .long, help: "Display name (defaults to the id).")
    var name: String?

    @Option(name: .long, help: "Reference WAV file.")
    var audio: String

    @Option(name: .long, help: "Transcript of the clip.")
    var transcript: String?

    @Option(name: .long, help: "File holding the transcript.")
    var transcriptFile: String?

    func validate() throws {
        if (transcript == nil) == (transcriptFile == nil) {
            throw ValidationError(
                "pass exactly one of --transcript or --transcript-file"
            )
        }
    }

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let text: String
        if let transcriptFile {
            do {
                text = try String(
                    contentsOfFile: transcriptFile,
                    encoding: .utf8
                )
            } catch {
                throw ValidationError("cannot read \(transcriptFile)")
            }
        } else {
            text = transcript ?? ""
        }
        let url = URL(fileURLWithPath: audio)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ValidationError("cannot read \(audio)")
        }
        let id = id
        let name = name ?? id
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let res = try request {
            try await client.addVoice(
                id: id,
                name: name,
                audioURL: url,
                transcript: clean
            )
        }
        print("added \(res.id)\t\(res.displayName)")
    }
}

struct VoiceRename: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Change a voice's display name (PATCH /voices/<id>)."
    )

    @Argument(help: "Voice id.")
    var id: String

    @Argument(help: "New display name.")
    var name: String

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let id = id
        let name = name
        let res = try request {
            try await client.renameVoice(id: id, displayName: name)
        }
        print("renamed \(res.id)\t\(res.displayName)")
    }
}

struct VoiceDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a voice (DELETE /voices/<id>)."
    )

    @Argument(help: "Voice id.")
    var id: String

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let id = id
        _ = try request { try await client.deleteVoice(id: id) }
        print("deleted \(id)")
    }
}

struct Effects: ParsableCommand {
    enum Setting: String, ExpressibleByArgument {
        case on, off
    }

    static let configuration = CommandConfiguration(
        abstract: "Toggle synthesis effects (PATCH /settings)."
    )

    @Argument(help: "on or off.")
    var setting: Setting

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let update = SettingsUpdateRequest(
            effects: setting == .on,
            defaultRate: nil
        )
        let res = try request { try await client.updateSettings(update) }
        print(res.effects == true ? "effects on" : "effects off")
    }
}

struct StateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Print the server's /state as JSON."
    )

    @Flag(name: .long, help: "Emit JSON (required).")
    var json = false

    @OptionGroup var options: ClientOptions

    func validate() throws {
        guard json else {
            throw ValidationError("state output requires --json")
        }
    }

    func run() throws {
        let client = options.client()
        let state = try request { try await client.state() }
        let data = try DaemonClient.encoder.encode(state)
        print(String(decoding: data, as: UTF8.self))
    }
}

enum StatusReport {
    static func lines(host: String, state: DaemonStateResponse) -> [String] {
        let active = state.activeClient.map { $0.label ?? $0.channel }
        var lines = [
            "endpoint:      \(host)",
            "ready:         \(state.ready)"
                + (state.error.map { " (\($0))" } ?? ""),
            "backend:       \(state.backend ?? "-")",
            "voice:         \(state.activeVoice ?? "-")",
            "effects:       \(state.effects == true ? "on" : "off")",
            "active client: \(active ?? "none")",
        ]
        for (name, info) in (state.channels ?? [:]).sorted(by: {
            $0.key < $1.key
        }) {
            let flags = [
                info.speaking ? "speaking" : nil,
                info.paused ? "paused" : nil,
                info.pending > 0 ? "\(info.pending) pending" : nil,
            ].compactMap { $0 }
            let label = info.label.map { " (\($0))" } ?? ""
            let detail = flags.isEmpty ? "idle" : flags.joined(separator: ", ")
            lines.append("channel:       \(name)\(label): \(detail)")
        }
        return lines
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Summarize server state (GET /state)."
    )

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        let state = try request { try await client.state() }
        StatusReport.lines(host: client.host, state: state)
            .forEach { print($0) }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose endpoint, active client, and audio output."
    )

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client()
        var healthy = true
        print("endpoint:      \(client.host)")
        print("this mac:      \(ClientChannel.defaultChannel())")
        do {
            let state = try blocking { try await client.state() }
            print("connection:    ok")
            print("ready:         \(state.ready)"
                + (state.error.map { " (\($0))" } ?? ""))
            healthy = healthy && state.ready
            if let active = state.activeClient {
                print("active client: \(active.label ?? active.channel)"
                    + " [\(active.channel)]")
            } else {
                print("active client: none: CLI speech will fail with 409")
                healthy = false
            }
        } catch {
            print("connection:    FAILED (\(error))")
            healthy = false
        }

        do {
            let snapshot = try CoreAudioOutputDeviceProvider().snapshot()
            print("output device: \(snapshot.defaultDevice.device.name)")
        } catch {
            print("output device: unavailable (\(error))")
        }
        if !healthy { throw ExitCode(1) }
    }
}
