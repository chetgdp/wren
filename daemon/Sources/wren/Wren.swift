import ArgumentParser
import Foundation

@main
struct Wren: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wren",
        abstract: "The wren TTS daemon: menu bar app (default) "
            + "and CLI for tts/serve.py.",
        subcommands: [
            RunApp.self, Say.self, Yell.self, Stop.self, Pause.self,
            Resume.self, Voices.self, Voice.self, Effects.self,
            StateCommand.self, Status.self, Doctor.self,
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
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Daemon host:port (default: $WREN_HOST or "
                + "\(DaemonClient.defaultHost))."))
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

/// Where say/yell text comes from: arguments joined with spaces (fish
/// substitutions split lines into words, loose typing gives several
/// arguments), else piped stdin. Injectable so tests need no real pipe.
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
            throw ValidationFailure(
                "no text to speak: pass words or pipe text in")
        }
        let text = String(decoding: readStdin(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ValidationFailure("no text to speak: stdin was empty")
        }
        return text
    }
}

struct Say: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Speak text through the daemon (POST /speak)."
    )

    @Argument(
        help: ArgumentHelp(
            "Text to speak; several arguments are joined, "
                + "none reads stdin."))
    var text: [String] = []

    @Flag(name: .long, help: "Skip the daemon's markdown stripping.")
    var raw: Bool = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Playback speed 0.5-3.0, pitch-preserving; "
                + "sticks until changed."))
    var speed: Double?

    @OptionGroup var options: ClientOptions

    // Always queue: concurrent callers (user + agents) must never cut each
    // other off; preemption is reserved for `wren stop`.
    var body: SpeakRequest {
        SpeakRequest(
            text: text.joined(separator: " "),
            append: true,
            raw: raw ? true : nil,
            speed: speed
        )
    }

    func run() throws {
        let client = options.client
        var payload = body
        payload.text = try SpeakInput.resolve(arguments: text)
        let request = payload
        do {
            let response: SpeakResponse = try blocking {
                try await client.post("/speak", body: request)
            }
            print("queued \(response.queued)")
        } catch {
            throw fail(error)
        }
    }
}

struct Yell: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Speak immediately, cutting off the current queue "
            + "(POST /speak)."
    )

    @Argument(
        help: ArgumentHelp(
            "Text to speak; several arguments are joined, "
                + "none reads stdin."))
    var text: [String] = []

    @Flag(name: .long, help: "Skip the daemon's markdown stripping.")
    var raw: Bool = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Playback speed 0.5-3.0, pitch-preserving; "
                + "sticks until changed."))
    var speed: Double?

    @OptionGroup var options: ClientOptions

    // The one deliberate preemption path: append stays off the wire so the
    // daemon cuts whatever is playing; `wren say` can never cut anyone off.
    var body: SpeakRequest {
        SpeakRequest(
            text: text.joined(separator: " "),
            append: nil,
            raw: raw ? true : nil,
            speed: speed
        )
    }

    func run() throws {
        let client = options.client
        var payload = body
        payload.text = try SpeakInput.resolve(arguments: text)
        let request = payload
        do {
            let response: SpeakResponse = try blocking {
                try await client.post("/speak", body: request)
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
            let _: StopResponse = try blocking {
                try await client.post("/stop")
            }
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

struct CLICommandFailure: Error, CustomStringConvertible {
    let description: String
}

func freshRequestID() -> String {
    UUID().uuidString
}

enum MutationResolution {
    typealias Delay = () async throws -> Void

    static func pollDelay() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    static func wait(
        client: DaemonClient,
        requestID: String,
        instanceID: String,
        initial: OperationResponse?,
        delay: @escaping Delay = pollDelay
    ) async throws -> OperationResponse {
        var operation = initial
        while true {
            if operation == nil {
                let meta = try await client.meta()
                try DaemonClient.validateIdentity(meta)
                guard meta.instanceID == instanceID else {
                    throw CLICommandFailure(
                        description: "daemon instance changed from "
                            + "\(instanceID) to \(meta.instanceID) while "
                            + "operation \(requestID) was running"
                    )
                }
                operation = try await client.operation(requestID: requestID)
            }
            guard let current = operation else {
                throw CLICommandFailure(
                    description: "operation \(requestID) disappeared"
                )
            }
            guard current.id == requestID else {
                throw CLICommandFailure(
                    description: "daemon returned operation \(current.id) "
                        + "for request \(requestID)"
                )
            }

            switch current.phase {
            case .succeeded:
                return current
            case .failed:
                if let error = current.error {
                    throw CLICommandFailure(
                        description: "\(error.code): \(error.message)"
                    )
                }
                throw CLICommandFailure(
                    description: "operation \(requestID) failed without "
                        + "error detail"
                )
            case .pending, .preparing, .committing:
                try await delay()
                operation = nil
            default:
                throw CLICommandFailure(
                    description: "operation \(requestID) has unknown phase "
                        + "'\(current.phase.rawValue)'"
                )
            }
        }
    }

    static func submit(
        client: DaemonClient,
        requestID: String,
        instanceID: String,
        delay: @escaping Delay = pollDelay,
        operation: () async throws -> OperationResponse
    ) async throws -> OperationResponse {
        let initial = try await submitAttempt(
            requestID: requestID,
            operation: operation)
        do {
            return try await wait(
                client: client,
                requestID: requestID,
                instanceID: instanceID,
                initial: initial,
                delay: delay)
        } catch {
            guard initial == nil, isUnknown(error) else { throw error }
        }
        try await validateInstance(
            client: client,
            instanceID: instanceID,
            requestID: requestID)
        let retried = try await submitAttempt(
            requestID: requestID,
            operation: operation)
        return try await wait(
            client: client,
            requestID: requestID,
            instanceID: instanceID,
            initial: retried,
            delay: delay)
    }

    static func validateInstance(
        client: DaemonClient,
        instanceID: String,
        requestID: String
    ) async throws {
        let meta = try await client.meta()
        try DaemonClient.validateIdentity(meta)
        guard meta.instanceID == instanceID else {
            throw CLICommandFailure(
                description: "daemon instance changed from \(instanceID) "
                    + "to \(meta.instanceID) while operation \(requestID) "
                    + "was running")
        }
    }

    static func isUnknown(_ error: Error) -> Bool {
        guard case .management(_, let detail) = error as? DaemonError else {
            return false
        }
        return detail.code == "operation_result_unknown"
    }

    private static func submitAttempt(
        requestID: String,
        operation: () async throws -> OperationResponse
    ) async throws -> OperationResponse? {
        do {
            return try await operation()
        } catch let error as DaemonError {
            guard case .ambiguousSubmittedMutation(
                let ambiguousID,
                _
            ) = error, ambiguousID == requestID else {
                throw error
            }
            return nil
        }
    }
}

struct Voices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List daemon voice profiles (GET /voices)."
    )

    @OptionGroup var options: ClientOptions

    static func output(_ response: VoiceListResponse) -> [String] {
        guard !response.voices.isEmpty else { return ["no voices"] }
        return response.voices.flatMap { profile in
            var lines = [
                "\(profile.id)\t\(profile.displayName)"
                    + "\t\(profile.status.rawValue)",
            ]
            lines += profile.issues.map { issue in
                let field = issue.field.map { "\($0): " } ?? ""
                return "  \(field)\(issue.message) [\(issue.code)]"
            }
            return lines
        }
    }

    static func execute(client: DaemonClient) async throws -> [String] {
        let meta = try await client.meta()
        try DaemonClient.validateIdentity(
            meta,
            requiredCapabilities: [.voiceList])
        return output(try await client.voices())
    }

    func run() throws {
        do {
            let lines = try blocking {
                try await Self.execute(client: options.client)
            }
            lines.forEach { print($0) }
        } catch {
            throw fail(error)
        }
    }
}

struct Voice: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the active daemon voice.",
        subcommands: [VoiceUse.self]
    )
}

struct VoiceUse: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Activate a ready voice profile."
    )

    @Argument(help: "Stable voice profile ID.")
    var voice: String

    @OptionGroup var options: ClientOptions

    static func execute(
        client: DaemonClient,
        voice: String,
        requestID: String = freshRequestID(),
        delay: @escaping MutationResolution.Delay =
            MutationResolution.pollDelay
    ) async throws -> String {
        let meta = try await client.meta()
        try DaemonClient.validateIdentity(
            meta,
            requiredCapabilities: [.voiceActivate]
        )
        _ = try await MutationResolution.submit(
            client: client,
            requestID: requestID,
            instanceID: meta.instanceID,
            delay: delay
        ) {
            try await client.activateVoice(
                voice,
                requestID: requestID)
        }
        return "voice \(voice)"
    }

    func run() throws {
        do {
            let line = try blocking {
                try await Self.execute(
                    client: options.client,
                    voice: voice
                )
            }
            print(line)
        } catch {
            throw fail(error)
        }
    }
}

struct Effects: ParsableCommand {
    enum Setting: String, ExpressibleByArgument {
        case on
        case off

        var enabled: Bool { self == .on }
    }

    static let configuration = CommandConfiguration(
        abstract: "Enable or disable daemon synthesis effects."
    )

    @Argument(help: "The new daemon-global effects setting.")
    var setting: Setting

    @OptionGroup var options: ClientOptions

    static func execute(
        client: DaemonClient,
        setting: Setting,
        requestID: String = freshRequestID(),
        delay: @escaping MutationResolution.Delay =
            MutationResolution.pollDelay
    ) async throws -> String {
        let meta = try await client.meta()
        try DaemonClient.validateIdentity(
            meta,
            requiredCapabilities: [.settingsV2]
        )
        let update = SettingsUpdateRequest(
            effects: setting.enabled,
            defaultSynthesisRate: nil)
        let state: DaemonStateResponse
        do {
            state = try await client.updateSettings(
                update,
                requestID: requestID)
        } catch let error as DaemonError {
            guard case .ambiguousSubmittedMutation(
                let ambiguousID,
                _
            ) = error, ambiguousID == requestID else {
                throw error
            }
            do {
                _ = try await MutationResolution.wait(
                    client: client,
                    requestID: requestID,
                    instanceID: meta.instanceID,
                    initial: nil,
                    delay: delay)
            } catch {
                guard MutationResolution.isUnknown(error) else {
                    throw error
                }
                try await MutationResolution.validateInstance(
                    client: client,
                    instanceID: meta.instanceID,
                    requestID: requestID)
                do {
                    state = try await client.updateSettings(
                        update,
                        requestID: requestID)
                    return state.synthesis.effects
                        ? "effects on"
                        : "effects off"
                } catch let retryError as DaemonError {
                    guard case .ambiguousSubmittedMutation(
                        let retryID,
                        _
                    ) = retryError, retryID == requestID else {
                        throw retryError
                    }
                    _ = try await MutationResolution.wait(
                        client: client,
                        requestID: requestID,
                        instanceID: meta.instanceID,
                        initial: nil,
                        delay: delay)
                }
            }
            state = try await client.state()
        }
        return state.synthesis.effects ? "effects on" : "effects off"
    }

    func run() throws {
        do {
            let line = try blocking {
                try await Self.execute(
                    client: options.client,
                    setting: setting
                )
            }
            print(line)
        } catch {
            throw fail(error)
        }
    }
}

struct StateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Print daemon management state as JSON."
    )

    @Flag(name: .long, help: "Emit stable snake_case JSON.")
    var json = false

    @OptionGroup var options: ClientOptions

    func validate() throws {
        guard json else {
            throw ArgumentParser.ValidationError(
                "state output requires --json"
            )
        }
    }

    static func output(_ state: DaemonStateResponse) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return String(
            decoding: try encoder.encode(state),
            as: UTF8.self
        )
    }

    static func execute(client: DaemonClient) async throws -> String {
        let meta = try await client.meta()
        try DaemonClient.validateIdentity(
            meta,
            requiredCapabilities: [.stateV2])
        return try output(try await client.state())
    }

    func run() throws {
        do {
            print(try blocking {
                try await Self.execute(client: options.client)
            })
        } catch {
            throw fail(error)
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show effective daemon status (GET /meta and /state)."
    )

    @OptionGroup var options: ClientOptions

    static func output(
        meta: MetaResponse,
        state: DaemonStateResponse
    ) -> [String] {
        var lifecycle = state.lifecycle.phase.rawValue
        if let message = state.lifecycle.message {
            lifecycle += " (\(message))"
        }
        var operation = "-"
        if let active = state.operation {
            operation = "\(active.kind) \(active.phase.rawValue)"
            if let target = active.target {
                operation += " \(target)"
            }
            if let progress = active.progress {
                operation += " \(Int(progress * 100))%"
            }
        }
        return [
            "service:   \(meta.service) protocol \(meta.protocolVersion)",
            "instance:  \(meta.instanceID)",
            "lifecycle: \(lifecycle)",
            "voice:     \(state.synthesis.activeVoice ?? "-")",
            "backend:   \(state.synthesis.backend)",
            "playback:  speaking=\(state.playback.speaking) "
                + "paused=\(state.playback.paused) "
                + "pending=\(state.playback.pending)",
            "operation: \(operation)",
        ]
    }

    static func execute(client: DaemonClient) async throws -> [String] {
        let meta = try await client.meta()
        try DaemonClient.validateIdentity(
            meta,
            requiredCapabilities: [.stateV2]
        )
        return output(meta: meta, state: try await client.state())
    }

    func run() throws {
        do {
            let lines = try blocking {
                try await Self.execute(client: options.client)
            }
            lines.forEach { print($0) }
        } catch {
            throw fail(error)
        }
    }
}

struct DoctorLocalSnapshot: Equatable, Sendable {
    let settingsPresent: Bool
    let migrationSourcePresent: Bool
    let missingAssets: [String]
    let output: String
    let loginItem: LoginItemState
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose management-v2 and local macOS state."
    )

    @OptionGroup var options: ClientOptions

    static func output(
        configuredHost: String,
        meta: MetaResponse,
        state: DaemonStateResponse,
        voices: VoiceListResponse,
        local: DoctorLocalSnapshot
    ) -> [String] {
        let capabilities = meta.capabilities
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let effectiveHost = state.synthesis.host ?? "unknown"
        let effectivePort = state.synthesis.port.map(String.init) ?? "unknown"
        let readyVoices = voices.voices.filter {
            $0.status == .ready
        }.count
        let unavailableVoices = voices.voices.count - readyVoices
        let issueCount = voices.voices.reduce(0) {
            $0 + $1.issues.count
        }
        let settingsStatus = local.settingsPresent
            ? "settings.json present"
            : "settings.json absent"
        let migrationStatus = local.migrationSourcePresent
            ? "legacy migration source retained"
            : "no legacy migration source"
        let assets = local.missingAssets.isEmpty
            ? "local assets ready"
            : "missing local assets: "
                + local.missingAssets.joined(separator: ", ")
        let login = loginItemDescription(local.loginItem)

        return [
            "protocol: wren v\(meta.protocolVersion) "
                + "instance=\(meta.instanceID) capabilities=\(capabilities)",
            "endpoint: configured=\(configuredHost) "
                + "effective=\(effectiveHost):\(effectivePort)",
            "state: revision=\(state.revision) "
                + "lifecycle=\(state.lifecycle.phase.rawValue)",
            "settings: effects=\(state.synthesis.effects) "
                + "default_rate=\(state.synthesis.defaultSynthesisRate) "
                + "\(settingsStatus); \(migrationStatus)",
            "voices: revision=\(voices.revision) ready=\(readyVoices) "
                + "unavailable=\(unavailableVoices) issues=\(issueCount) "
                + "active=\(state.synthesis.activeVoice ?? "-")",
            "engine: backend=\(state.synthesis.backend) "
                + "model=\(state.synthesis.model); \(assets)",
            "output: \(local.output)",
            "login item: \(login)",
        ]
    }

    static func execute(client: DaemonClient) async -> [String] {
        let local = localSnapshot()
        do {
            let meta = try await client.meta()
            try DaemonClient.validateIdentity(
                meta,
                requiredCapabilities: [
                    .stateV2,
                    .voiceList,
                    .voiceActivate,
                    .settingsV2,
                    .segmentPlayer,
                ])
            let state = try await client.state()
            let voices = try await client.voices()
            return output(
                configuredHost: client.host,
                meta: meta,
                state: state,
                voices: voices,
                local: local)
        } catch {
            return failureOutput(
                configuredHost: client.host,
                error: error,
                local: local)
        }
    }

    func run() throws {
        let client = options.client
        let lines = try blocking {
            await Self.execute(client: client)
        }
        lines.forEach { print($0) }
    }

    static func failureOutput(
        configuredHost: String,
        error: Error,
        local: DoctorLocalSnapshot
    ) -> [String] {
        let settings = local.settingsPresent
            ? "settings.json present"
            : "settings.json absent"
        let migration = local.migrationSourcePresent
            ? "legacy migration source retained"
            : "no legacy migration source"
        let assets = local.missingAssets.isEmpty
            ? "local assets ready"
            : "missing local assets: "
                + local.missingAssets.joined(separator: ", ")
        return [
            "protocol: unavailable (\(error))",
            "endpoint: configured=\(configuredHost) conflict or unavailable",
            "state: unavailable",
            "settings: \(settings); \(migration)",
            "voices: unavailable",
            "engine: \(assets)",
            "output: \(local.output)",
            "login item: \(loginItemDescription(local.loginItem))",
        ]
    }

    private static func localSnapshot(
        paths: WrenPaths = .standard(),
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        audioDevices: AudioOutputDeviceProviding =
            CoreAudioOutputDeviceProvider(),
        loginItem: LoginItemProviding = NativeLoginItem()
    ) -> DoctorLocalSnapshot {
        let assets = [
            ("python environment", paths.python),
            ("daemon server", paths.servePy),
            ("qwentts engine", paths.engineBinary),
        ] + ModelFile.all.map {
            ("model \($0.name)", paths.models.appendingPathComponent($0.name))
        }
        let missingAssets = assets.compactMap { name, url in
            fileManager.fileExists(atPath: url.path) ? nil : name
        }
        return DoctorLocalSnapshot(
            settingsPresent: fileManager.fileExists(
                atPath: paths.settingsFile.path),
            migrationSourcePresent: fileManager.fileExists(
                atPath: paths.configFile.path),
            missingAssets: missingAssets,
            output: outputDescription(
                devices: audioDevices,
                userDefaults: userDefaults),
            loginItem: loginItem.refresh())
    }

    private static func outputDescription(
        devices: AudioOutputDeviceProviding,
        userDefaults: UserDefaults
    ) -> String {
        do {
            let snapshot = try devices.snapshot()
            guard let uid = userDefaults.string(
                forKey: WrenStore.outputUIDKey
            ) else {
                return "system default "
                    + "(\(snapshot.defaultDevice.device.name))"
            }
            if let selected = snapshot.devices.first(
                where: { $0.uid == uid }
            ) {
                return "selected \(selected.name) [\(uid)]"
            }
            let savedName = userDefaults.string(
                forKey: WrenStore.outputNameKey
            ) ?? uid
            return "selected \(savedName) unavailable; effective system "
                + "default (\(snapshot.defaultDevice.device.name))"
        } catch {
            return "unavailable (\(error))"
        }
    }

    private static func loginItemDescription(
        _ state: LoginItemState
    ) -> String {
        let status: String
        if !state.isAvailable {
            status = "unavailable (CLI cannot query "
                + "authoritative native-app login state)"
        } else {
            status = state.isEnabled ? "enabled" : "disabled"
        }
        guard let error = state.error else { return status }
        return "\(status) (\(error))"
    }
}
