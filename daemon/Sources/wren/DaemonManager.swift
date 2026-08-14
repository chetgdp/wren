import Foundation

protocol ManagedDaemonChild: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

private final class ProcessDaemonChild: ManagedDaemonChild,
    @unchecked Sendable {
    private let process: Process

    init(
        executable: URL,
        arguments: [String],
        directory: URL,
        output: FileHandle,
        onExit: @escaping @Sendable () -> Void
    ) throws {
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in onExit() }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        process.terminate()
    }
}

/// Owns at most one daemon child at one configured endpoint.
///
/// A process already listening at the endpoint is adopted only after an
/// authenticated management-v2 identity handshake. Only a refused connection
/// permits provisioning and launch. A connected process is never terminated.
final class DaemonManager: @unchecked Sendable {
    enum Ownership: Equatable, Sendable {
        case managed
        case connected
    }

    enum Phase: Equatable, Sendable {
        case starting
        case provisioning(String)
        case ready
        case recovering(attempt: Int, delay: TimeInterval)
        case failed
    }

    struct Failure: Error, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case connectionRefused
            case authorization
            case originAccess
            case identity
            case compatibility
            case transport
            case decoding
            case provisioning
            case launch
            case childExited
            case circuitOpen
            case unsupportedAction
            case resetInvalidSettings
        }

        let kind: Kind
        let message: String
        let canRetry: Bool
        let canResetInvalidSettings: Bool
    }

    struct State: Equatable, Sendable {
        let phase: Phase
        let ownership: Ownership?
        let endpoint: URL
        let error: Failure?
        let logLocation: URL?
        let libraryLocation: URL?
        let meta: MetaResponse?
    }

    enum ProbeResult: Equatable, Sendable {
        case response(MetaResponse)
        case refused
        case authorization(String?)
        case originAccess(String?)
        case transport(String)
        case decoding(String)
    }

    struct Dependencies: Sendable {
        typealias Launch = @Sendable (
            URL,
            [String],
            URL,
            FileHandle,
            @escaping @Sendable () -> Void
        ) throws -> ManagedDaemonChild

        typealias Schedule = @Sendable (
            TimeInterval,
            @escaping @Sendable () -> Void
        ) -> Void

        let probeMeta: @Sendable (URL, String?) -> ProbeResult
        let canSpawn: @Sendable (WrenPaths) -> Bool
        let provision: @Sendable (
            WrenPaths,
            @escaping @Sendable (ProvisionStep) -> Void
        ) throws -> Void
        let launch: Launch
        let openLog: @Sendable () throws -> FileHandle
        let resetInvalidSettings: @Sendable (WrenPaths) throws -> Void
        let now: @Sendable () -> Date
        let sleep: @Sendable (useconds_t) -> Void
        let schedule: Schedule

        static let live = Dependencies(
            probeMeta: { url, token in
                DaemonManager.probeMeta(url, token: token)
            },
            canSpawn: { $0.hasServerFiles },
            provision: { paths, progress in
                try Provisioner(paths: paths, progress: progress).ensure()
            },
            launch: { executable, arguments, directory, output, onExit in
                try ProcessDaemonChild(
                    executable: executable,
                    arguments: arguments,
                    directory: directory,
                    output: output,
                    onExit: onExit
                )
            },
            openLog: {
                try DaemonManager.logHandle()
            },
            resetInvalidSettings: { paths in
                try DaemonManager.quarantineInvalidConfiguration(
                    paths: paths)
            },
            now: { Date() },
            sleep: { duration in
                _ = usleep(duration)
            },
            schedule: { delay, work in
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + delay,
                    execute: work
                )
            }
        )
    }

    private static let requiredCapabilities: Set<DaemonCapability> = [
        .stateV2,
        .voiceList,
        .voiceActivate,
        .settingsV2,
        .segmentPlayer,
    ]
    private static let rapidExitWindow: TimeInterval = 10
    private static let maximumRapidExits = 3
    private static let maximumBackoff: TimeInterval = 8
    private static let readinessAttempts = 8

    private let queue = DispatchQueue(label: "wren.daemon-manager")
    private let paths: WrenPaths
    private let baseURL: URL
    private let token: String?
    private let dependencies: Dependencies
    private var child: ManagedDaemonChild?
    private var childGeneration: UUID?
    private var spawnedAt = Date.distantPast
    private var rapidExits = 0
    private var quitting = false
    private var restartOnExit = false
    private var ownership: Ownership?
    private var acceptedMeta: MetaResponse?

    private(set) var state: State {
        didSet { onState?(state) }
    }

    var onState: (@Sendable (State) -> Void)?

    init(
        paths: WrenPaths,
        baseURL: URL,
        token: String? = nil,
        dependencies: Dependencies = .live
    ) {
        self.paths = paths
        self.baseURL = baseURL
        self.token = token
        self.dependencies = dependencies
        state = State(
            phase: .starting,
            ownership: nil,
            endpoint: baseURL,
            error: nil,
            logLocation: nil,
            libraryLocation: nil,
            meta: nil
        )
    }

    /// serve.py invocation against bundle + Application Support paths only.
    /// The legacy config is an explicitly named migration source, never
    /// inspected for runtime intent. A seed reference is needed only before
    /// management-v2 settings exist.
    static func serveArguments(
        paths: WrenPaths,
        settingsExist: Bool
    ) -> [String] {
        var arguments = [
            paths.servePy.path,
            "--local-player", "client",
            "-b", "qwentts",
            "--qwentts-bin", paths.engineBinary.path,
            "--qwentts-model",
            paths.models
                .appendingPathComponent(ModelFile.all[0].name).path,
            "--qwentts-codec",
            paths.models
                .appendingPathComponent(ModelFile.all[1].name).path,
            "--voices-dir", paths.voices.path,
            "--config", paths.configFile.path,
        ]
        if !settingsExist {
            arguments += [
                "--initial-voice",
                WrenPaths.bundledSeedVoiceID,
            ]
        }
        return arguments
    }

    static func quarantineInvalidConfiguration(
        paths: WrenPaths,
        identifier: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws {
        let suffix = identifier.uuidString.lowercased()
        for source in [paths.settingsFile, paths.configFile]
            where fileManager.fileExists(atPath: source.path) {
            let backup = source.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(source.lastPathComponent).invalid-\(suffix).backup")
            try fileManager.moveItem(at: source, to: backup)
        }
    }

    func start() {
        queue.async { self.startLocked() }
    }

    /// Synchronously terminates only the child launched by this manager.
    func shutdown() {
        queue.sync {
            quitting = true
            restartOnExit = false
            guard ownership == .managed,
                  let child,
                  child.isRunning
            else {
                return
            }
            child.terminate()
            for _ in 0..<30 where child.isRunning {
                dependencies.sleep(100_000)
            }
        }
    }

    /// Restarts only an owned child. Connected mode reports an honest error.
    func restart() {
        queue.async {
            guard self.ownership == .managed else {
                self.reportUnsupported("Restart is unavailable in connected "
                    + "mode because Wren does not own that process.")
                return
            }
            guard let child = self.child, child.isRunning else {
                self.rapidExits = 0
                self.startLocked()
                return
            }
            self.restartOnExit = true
            child.terminate()
        }
    }

    func retry() {
        queue.async {
            guard self.state.phase == .failed else {
                self.reportUnsupported(
                    "Retry is available only after a lifecycle failure."
                )
                return
            }
            self.rapidExits = 0
            self.startLocked()
        }
    }

    func resetInvalidSettings() {
        queue.async {
            guard self.ownership == .managed else {
                self.reportUnsupported(
                    "Settings reset is unavailable in connected mode because "
                    + "Wren does not own that daemon or its settings."
                )
                return
            }
            do {
                try self.dependencies.resetInvalidSettings(self.paths)
                self.rapidExits = 0
                if let child = self.child, child.isRunning {
                    self.restartOnExit = true
                    child.terminate()
                } else {
                    self.startLocked()
                }
            } catch {
                self.fail(
                    kind: .resetInvalidSettings,
                    message: "Could not reset daemon settings: \(error)",
                    canRetry: true,
                    canReset: true
                )
            }
        }
    }

    private func startLocked() {
        guard !quitting else { return }
        publish(
            phase: .starting,
            ownership: ownership,
            error: nil,
            meta: acceptedMeta
        )
        switch dependencies.probeMeta(baseURL, token) {
        case .response(let meta):
            accept(meta)
        case .refused:
            beginManagedLaunch()
        case .authorization(let detail):
            fail(
                kind: .authorization,
                message: detail
                    ?? "Authorization failed at \(endpointDescription).",
                canRetry: true
            )
        case .originAccess(let detail):
            fail(
                kind: .originAccess,
                message: detail
                    ?? "Origin policy denied access at \(endpointDescription).",
                canRetry: true
            )
        case .decoding(let description):
            fail(
                kind: .decoding,
                message: "Could not decode Wren identity at "
                    + "\(endpointDescription): \(description)",
                canRetry: true
            )
        case .transport(let description):
            fail(
                kind: .transport,
                message: "Could not reach \(endpointDescription): "
                    + description,
                canRetry: true
            )
        }
    }

    private func accept(_ meta: MetaResponse) {
        do {
            try DaemonClient.validateIdentity(
                meta,
                requiredCapabilities: Self.requiredCapabilities
            )
        } catch DaemonError.identity(let service) {
            fail(
                kind: .identity,
                message: "\(endpointDescription) identifies as "
                    + "'\(service)', not Wren.",
                canRetry: true
            )
            return
        } catch DaemonError.identityMetadata(let description) {
            fail(
                kind: .identity,
                message: "Invalid Wren identity at "
                    + "\(endpointDescription): \(description)",
                canRetry: true
            )
            return
        } catch DaemonError.compatibility(let version, let missing) {
            var details = "protocol \(version)"
            if !missing.isEmpty {
                details += "; missing "
                    + missing.map(\.rawValue).joined(separator: ", ")
            }
            fail(
                kind: .compatibility,
                message: "Incompatible Wren at \(endpointDescription): "
                    + details + ".",
                canRetry: true
            )
            return
        } catch {
            fail(
                kind: .compatibility,
                message: "Could not validate Wren identity at "
                    + "\(endpointDescription): \(error)",
                canRetry: true
            )
            return
        }
        acceptedMeta = meta
        if let child, child.isRunning {
            ownership = .managed
        } else {
            ownership = .connected
        }
        publish(
            phase: .ready,
            ownership: ownership,
            error: nil,
            meta: meta
        )
    }

    private func beginManagedLaunch() {
        if let child,
           child.isRunning,
           let generation = childGeneration {
            waitForManagedReadiness(
                attempt: 1,
                generation: generation
            )
            return
        }
        guard dependencies.canSpawn(paths) else {
            fail(
                kind: .connectionRefused,
                message: "Connection refused at \(endpointDescription), and "
                    + "this build has no bundled server.",
                canRetry: true
            )
            return
        }
        do {
            try dependencies.provision(paths) { [weak self] step in
                self?.reportProvisioning(step)
            }
        } catch {
            fail(
                kind: .provisioning,
                message: "Could not provision Wren at "
                    + "\(endpointDescription): \(error)",
                canRetry: true
            )
            return
        }
        do {
            try spawn()
        } catch {
            fail(
                kind: .launch,
                message: "Could not launch Wren at "
                    + "\(endpointDescription): \(error)",
                canRetry: true
            )
        }
    }

    private func reportProvisioning(_ step: ProvisionStep) {
        switch step {
        case .pythonEnv:
            publish(
                phase: .provisioning("setting up python…"),
                ownership: ownership,
                error: nil,
                meta: nil
            )
        case .model(let name, let done, let total):
            let fraction = total > 0 ? Double(done) / Double(total) : 0
            let percent = Int(fraction * 100)
            let short = name.hasPrefix("qwen-talker")
                ? "voice model"
                : "codec"
            publish(
                phase: .provisioning(
                    "downloading \(short)… \(percent)%"
                ),
                ownership: ownership,
                error: nil,
                meta: nil
            )
        case .ready:
            break
        }
    }

    private func spawn() throws {
        var arguments = Self.serveArguments(
            paths: paths,
            settingsExist: FileManager.default.fileExists(
                atPath: paths.settingsFile.path
            )
        )
        if let host = baseURL.host {
            arguments += ["--host", host]
        }
        if let port = baseURL.port {
            arguments += ["--port", String(port)]
        }
        if let token {
            arguments += ["--token", token]
        }
        let log = try dependencies.openLog()
        let generation = UUID()
        let launched = try dependencies.launch(
            paths.python,
            arguments,
            paths.appSupport,
            log
        ) { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.childExited(generation: generation)
            }
        }
        child = launched
        childGeneration = generation
        ownership = .managed
        acceptedMeta = nil
        spawnedAt = dependencies.now()
        publish(
            phase: .starting,
            ownership: .managed,
            error: nil,
            meta: nil
        )
        waitForManagedReadiness(attempt: 1, generation: generation)
    }

    private func waitForManagedReadiness(
        attempt: Int,
        generation: UUID
    ) {
        guard generation == childGeneration,
              let child,
              child.isRunning
        else {
            return
        }
        switch dependencies.probeMeta(baseURL, token) {
        case .response(let meta):
            accept(meta)
        case .refused where attempt < Self.readinessAttempts:
            let delay = min(
                0.25 * pow(2, Double(attempt - 1)),
                Self.maximumBackoff
            )
            dependencies.schedule(delay) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.waitForManagedReadiness(
                        attempt: attempt + 1,
                        generation: generation
                    )
                }
            }
        case .refused:
            fail(
                kind: .connectionRefused,
                message: "Managed Wren did not become ready at "
                    + "\(endpointDescription); see \(Self.logPath.path).",
                canRetry: true
            )
        case .authorization(let detail):
            fail(
                kind: .authorization,
                message: detail
                    ?? "Managed Wren rejected its configured token.",
                canRetry: true
            )
        case .originAccess(let detail):
            fail(
                kind: .originAccess,
                message: detail
                    ?? "Managed Wren rejected this client's Origin policy.",
                canRetry: true
            )
        case .decoding(let description):
            fail(
                kind: .decoding,
                message: "Managed Wren returned invalid identity data: "
                    + description,
                canRetry: true
            )
        case .transport(let description):
            fail(
                kind: .transport,
                message: "Managed Wren probe failed: \(description)",
                canRetry: true
            )
        }
    }

    private func childExited(generation: UUID) {
        let exitedOwnedChild = ownership == .managed
        guard generation == childGeneration else { return }
        child = nil
        childGeneration = nil
        acceptedMeta = nil
        guard exitedOwnedChild else { return }
        guard !quitting else { return }
        if restartOnExit {
            restartOnExit = false
            rapidExits = 0
            do {
                try spawn()
            } catch {
                fail(
                    kind: .launch,
                    message: "Could not restart managed Wren: \(error)",
                    canRetry: true
                )
            }
            return
        }
        let lifetime = dependencies.now().timeIntervalSince(spawnedAt)
        if lifetime < Self.rapidExitWindow {
            rapidExits += 1
        } else {
            rapidExits = 1
        }
        guard rapidExits < Self.maximumRapidExits else {
            fail(
                kind: .circuitOpen,
                message: "Managed Wren keeps exiting; see "
                    + "\(Self.logPath.path).",
                canRetry: true
            )
            return
        }
        let delay = min(
            pow(2, Double(rapidExits - 1)),
            Self.maximumBackoff
        )
        publish(
            phase: .recovering(attempt: rapidExits, delay: delay),
            ownership: .managed,
            error: Failure(
                kind: .childExited,
                message: "Managed Wren exited unexpectedly; retrying in "
                    + "\(delay) seconds.",
                canRetry: true,
                canResetInvalidSettings: false
            ),
            meta: nil
        )
        dependencies.schedule(delay) { [weak self] in
            guard let self else { return }
            self.queue.async { self.startLocked() }
        }
    }

    private func publish(
        phase: Phase,
        ownership: Ownership?,
        error: Failure?,
        meta: MetaResponse?
    ) {
        state = State(
            phase: phase,
            ownership: ownership,
            endpoint: baseURL,
            error: error,
            logLocation: ownership == .managed ? Self.logPath : nil,
            libraryLocation: ownership == .managed ? paths.voices : nil,
            meta: meta
        )
    }

    private func fail(
        kind: Failure.Kind,
        message: String,
        canRetry: Bool,
        canReset: Bool = false
    ) {
        publish(
            phase: .failed,
            ownership: ownership,
            error: Failure(
                kind: kind,
                message: message,
                canRetry: canRetry,
                canResetInvalidSettings: canReset
            ),
            meta: acceptedMeta
        )
    }

    private func reportUnsupported(_ message: String) {
        publish(
            phase: state.phase,
            ownership: ownership,
            error: Failure(
                kind: .unsupportedAction,
                message: message,
                canRetry: false,
                canResetInvalidSettings: false
            ),
            meta: acceptedMeta
        )
    }

    private var endpointDescription: String {
        baseURL.absoluteString
    }

    private static func probeMeta(
        _ baseURL: URL,
        token: String?
    ) -> ProbeResult {
        let metaURL = baseURL.appendingPathComponent("meta")
        var request = URLRequest(url: metaURL)
        request.timeoutInterval = 2
        if let token {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        let done = DispatchSemaphore(value: 0)
        let box = ProbeResultBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.value = classifyProbe(
                expectedURL: metaURL,
                data: data,
                response: response,
                error: error
            )
            done.signal()
        }.resume()
        done.wait()
        return box.value
    }

    static func classifyProbe(
        expectedURL: URL,
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) -> ProbeResult {
        if let urlError = error as? URLError {
            if urlError.code == .cannotConnectToHost {
                return .refused
            }
            return .transport(urlError.localizedDescription)
        }
        if let error {
            return .transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            return .transport("missing HTTP response")
        }
        guard http.url == expectedURL else {
            return .transport(
                "the /meta probe redirected away from the configured endpoint"
            )
        }
        let detail = errorMessage(in: data)
        switch http.statusCode {
        case 200:
            guard let data else {
                return .transport("empty /meta response")
            }
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any]
            else {
                return .transport("invalid JSON in /meta response")
            }
            guard let service = json["service"] as? String else {
                return .response(
                    invalidIdentityMeta(service: "unknown")
                )
            }
            guard service == "wren" else {
                return .response(invalidIdentityMeta(service: service))
            }
            do {
                let meta = try DaemonClient.decoder.decode(
                    MetaResponse.self,
                    from: data
                )
                return .response(meta)
            } catch {
                return .decoding(
                    "invalid Wren /meta response: \(error)"
                )
            }
        case 401:
            return .authorization(detail)
        case 403:
            return .originAccess(detail)
        default:
            let suffix = detail.map { ": \($0)" } ?? ""
            return .transport("HTTP \(http.statusCode)\(suffix)")
        }
    }

    private static func invalidIdentityMeta(
        service: String
    ) -> MetaResponse {
        MetaResponse(
            service: service,
            protocolVersion: 0,
            instanceID: "",
            startedAt: "",
            capabilities: []
        )
    }

    private static func errorMessage(in data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
            return nil
        }
        if let error = json["error"] as? String {
            return error
        }
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return nil
    }

    static let logPath = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/wren/serve.log")

    private static func logHandle() throws -> FileHandle {
        let manager = FileManager.default
        try manager.createDirectory(
            at: logPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: logPath.path) {
            manager.createFile(atPath: logPath.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logPath)
        handle.seekToEndOfFile()
        return handle
    }
}

private final class ProbeResultBox: @unchecked Sendable {
    var value: DaemonManager.ProbeResult = .transport(
        "probe did not complete"
    )
}
