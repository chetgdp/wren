import ArgumentParser
import Foundation

@main
struct Wren: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wren",
        abstract: "The wren TTS daemon: menu bar app (default) and CLI for tts/serve.py.",
        subcommands: [
            RunApp.self, Say.self, Yell.self, Stop.self, Pause.self,
            Resume.self, Speed.self, ConfigCommand.self, Status.self,
            Install.self,
        ],
        // Spotlight launches the bundle binary with no arguments; bare
        // `wren` in a terminal does the same thing on purpose (one
        // executable, one behavior). The CLI lives in the subcommands.
        defaultSubcommand: RunApp.self
    )
}

/// --host/--token shared by every subcommand; resolution order is
/// flag > WREN_HOST/WREN_TOKEN env > 127.0.0.1:8765 / no token.
struct ClientOptions: ParsableArguments {
    @Option(name: .long, help: "Daemon host:port (default: $WREN_HOST or \(DaemonClient.defaultHost)).")
    var host: String?

    @Option(name: .long, help: "Bearer token (default: $WREN_TOKEN).")
    var token: String?

    var client: DaemonClient {
        DaemonClient(
            host: DaemonClient.resolveHost(flag: host),
            token: DaemonClient.resolveToken(flag: token)
        )
    }
}

/// Report to stderr and exit nonzero without ArgumentParser's "Error:"
/// prefix, so scripts see the daemon's message verbatim.
func fail(_ error: Error) -> ExitCode {
    let message = String(describing: error)
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    return ExitCode(1)
}

struct Say: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Speak text through the daemon (POST /speak)."
    )

    @Argument(help: "Text to speak.")
    var text: String

    @Flag(name: .long, help: "Skip the daemon's markdown stripping.")
    var raw: Bool = false

    @Option(name: .long, help: "Playback speed 0.5-3.0, pitch-preserving; sticks until changed.")
    var speed: Double?

    @OptionGroup var options: ClientOptions

    // Always queue: concurrent callers (user + agents) must never cut each
    // other off; preemption is reserved for `wren stop`.
    var body: SpeakRequest {
        SpeakRequest(
            text: text,
            append: true,
            raw: raw ? true : nil,
            speed: speed
        )
    }

    func run() throws {
        let client = options.client
        let payload = body
        do {
            let response: SpeakResponse = try blocking {
                try await client.post("/speak", body: payload)
            }
            print("queued \(response.queued)")
        } catch {
            throw fail(error)
        }
    }
}

struct Yell: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Speak immediately, cutting off the current queue (POST /speak)."
    )

    @Argument(help: "Text to speak.")
    var text: String

    @Flag(name: .long, help: "Skip the daemon's markdown stripping.")
    var raw: Bool = false

    @Option(name: .long, help: "Playback speed 0.5-3.0, pitch-preserving; sticks until changed.")
    var speed: Double?

    @OptionGroup var options: ClientOptions

    // The one deliberate preemption path: append stays off the wire so the
    // daemon cuts whatever is playing; `wren say` can never cut anyone off.
    var body: SpeakRequest {
        SpeakRequest(
            text: text,
            append: nil,
            raw: raw ? true : nil,
            speed: speed
        )
    }

    func run() throws {
        let client = options.client
        let payload = body
        do {
            let response: SpeakResponse = try blocking {
                try await client.post("/speak", body: payload)
            }
            print("queued \(response.queued)")
        } catch {
            throw fail(error)
        }
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop speech and clear the queue (POST /stop)."
    )

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client
        do {
            let _: StopResponse = try blocking { try await client.post("/stop") }
            print("stopped")
        } catch {
            throw fail(error)
        }
    }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pause playback (POST /pause)."
    )

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client
        do {
            let response: PauseResponse = try blocking {
                try await client.post("/pause")
            }
            print(response.paused ? "paused" : "not paused")
        } catch {
            throw fail(error)
        }
    }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resume paused playback (POST /resume)."
    )

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client
        do {
            let response: PauseResponse = try blocking {
                try await client.post("/resume")
            }
            print(response.paused ? "still paused" : "resumed")
        } catch {
            throw fail(error)
        }
    }
}

struct Speed: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set and persist the playback speed (POST /config)."
    )

    @Argument(help: "Playback speed 0.5-3.0, pitch-preserving.")
    var value: Double

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client
        let update = ConfigUpdate(speed: value)
        do {
            let payload: ConfigPayload = try blocking {
                try await client.post("/config", body: update)
            }
            print("speed \(payload.speed)")
            reportPersistence(payload)
        } catch {
            throw fail(error)
        }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show the daemon config, or set one key (GET/POST /config)."
    )

    @Argument(help: "Config key to set (voice, voices_dir, speed, fx, port, backend).")
    var key: String?

    @Argument(help: "New value for the key.")
    var value: String?

    @OptionGroup var options: ClientOptions

    func validate() throws {
        if (key == nil) != (value == nil) {
            throw ArgumentParser.ValidationError("pass both a key and a value, or neither")
        }
    }

    func run() throws {
        let client = options.client
        do {
            let payload: ConfigPayload
            if let key, let value {
                let update = try ConfigUpdate.parsing(key: key, value: value)
                payload = try blocking {
                    try await client.post("/config", body: update)
                }
            } else {
                payload = try blocking { try await client.get("/config") }
            }
            printConfig(payload)
            reportPersistence(payload)
        } catch {
            throw fail(error)
        }
    }

    private func printConfig(_ payload: ConfigPayload) {
        print("voice:      \(payload.voice ?? "-")")
        print("voices_dir: \(payload.voicesDir ?? "-")")
        print("speed:      \(payload.speed)")
        print("fx:         \(payload.fx)")
        print("port:       \(payload.port)")
        print("backend:    \(payload.backend)")
    }
}

/// POST /config caveats the CLI must not swallow: an unpersisted change is
/// lost on restart, and a restart-only key isn't live until the daemon
/// comes back up.
private func reportPersistence(_ payload: ConfigPayload) {
    if payload.persisted == false {
        let detail = payload.persistError.map { " (\($0))" } ?? ""
        FileHandle.standardError.write(
            Data("warning: change is live but was not saved\(detail)\n".utf8))
    }
    if payload.restartRequired {
        FileHandle.standardError.write(
            Data("note: restart the daemon to apply this change\n".utf8))
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show daemon status (GET /health)."
    )

    @OptionGroup var options: ClientOptions

    func run() throws {
        let client = options.client
        do {
            let health: HealthResponse = try blocking {
                try await client.get("/health")
            }
            let yesNo = { (flag: Bool) in flag ? "yes" : "no" }
            print("ready:    \(health.ready ? "yes" : "no (model loading)")")
            print("model:    \(health.model)")
            print("speaking: \(yesNo(health.speaking))")
            print("paused:   \(yesNo(health.paused))")
            print("queue:    \(health.pending)")
            print("speed:    \(health.speed.map { "\($0)" } ?? "-")")
        } catch {
            throw fail(error)
        }
    }
}
