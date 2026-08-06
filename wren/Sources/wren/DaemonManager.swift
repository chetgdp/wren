import Foundation

/// Owns the serve.py child: adopt a daemon that already answers /health on
/// the config port (never double-launch), otherwise provision and spawn one
/// from the bundle. Quitting the app stops only a daemon it spawned.
final class DaemonManager: @unchecked Sendable {
    enum State: Equatable {
        case starting
        case provisioning(String)
        case adopted
        case spawned
        case failed(String)
    }

    private let queue = DispatchQueue(label: "wren.daemon-manager")
    private let paths: WrenPaths
    private let baseURL: URL
    private var child: Process?
    private var spawnedAt = Date.distantPast
    private var rapidExits = 0
    private var quitting = false
    private(set) var state = State.starting {
        didSet { onState?(state) }
    }

    var onState: (@Sendable (State) -> Void)?

    init(paths: WrenPaths, baseURL: URL) {
        self.paths = paths
        self.baseURL = baseURL
    }

    /// serve.py invocation against bundle + Application Support paths only.
    /// Pure so tests can pin the contract. The -r fallback covers a config
    /// with no voice set (first run): flags override the file for one run
    /// without being written back, so the config stays the truth once the
    /// user sets a voice.
    static func serveArguments(paths: WrenPaths, configHasVoice: Bool) -> [String] {
        var arguments = [
            paths.servePy.path,
            "--local-player", "client",
            "-b", "qwentts",
            "--qwentts-bin", paths.engineBinary.path,
            "--qwentts-model",
            paths.models.appendingPathComponent(ModelFile.all[0].name).path,
            "--qwentts-codec",
            paths.models.appendingPathComponent(ModelFile.all[1].name).path,
        ]
        if !configHasVoice {
            arguments += ["-r", paths.defaultVoiceWav.path]
        }
        return arguments
    }

    /// serve.py's config file names a voice (and its directory); when it
    /// does, the daemon resolves the ref audio itself.
    static func configHasVoice(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["voice"] is String && json["voices_dir"] is String
    }

    func start() {
        queue.async { self.startLocked() }
    }

    /// Terminate a spawned child (SIGTERM; serve.py cleans up its
    /// tts-server on it). Adopted daemons are not ours to kill.
    func shutdown() {
        // Synchronous on purpose: called from applicationWillTerminate,
        // after which the process is gone.
        queue.sync {
            quitting = true
            guard let child, child.isRunning else { return }
            child.terminate()
            // waitUntilExit can hang if the child ignores SIGTERM; poll
            // briefly and let launchd's cleanup catch a straggler.
            for _ in 0..<30 where child.isRunning {
                usleep(100_000)
            }
        }
    }

    private func startLocked() {
        if probeHealth() {
            state = .adopted
            return
        }
        guard paths.hasServerFiles else {
            state = .failed(
                "no daemon on \(baseURL.host ?? "?"):\(baseURL.port ?? 0) and "
                + "this build has no bundled server (run scripts/dev.sh)")
            return
        }
        do {
            let provisioner = Provisioner(paths: paths) { [weak self] step in
                self?.reportProvisioning(step)
            }
            try provisioner.ensure()
            try spawn()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    private func reportProvisioning(_ step: ProvisionStep) {
        switch step {
        case .pythonEnv:
            state = .provisioning("setting up python…")
        case .model(let name, let done, let total):
            let percent = total > 0 ? Int(Double(done) / Double(total) * 100) : 0
            let short = name.hasPrefix("qwen-talker") ? "voice model" : "codec"
            state = .provisioning("downloading \(short)… \(percent)%")
        case .ready:
            break
        }
    }

    private func spawn() throws {
        let process = Process()
        process.executableURL = paths.python
        process.arguments = Self.serveArguments(
            paths: paths,
            configHasVoice: Self.configHasVoice(at: paths.configFile))
        process.currentDirectoryURL = paths.appSupport
        let log = try logHandle()
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.childExited() }
        }
        try process.run()
        child = process
        spawnedAt = Date()
        state = .spawned
    }

    private func childExited() {
        child = nil
        guard !quitting else { return }
        // A child that dies right after spawn is a config/install problem;
        // respawning forever would just heat the machine.
        if Date().timeIntervalSince(spawnedAt) < 10 {
            rapidExits += 1
        } else {
            rapidExits = 0
        }
        guard rapidExits < 3 else {
            state = .failed("daemon keeps exiting; see \(Self.logPath.path)")
            return
        }
        state = .starting
        queue.asyncAfter(deadline: .now() + 2) { self.startLocked() }
    }

    /// Something already answering /health on the port is a wren daemon;
    /// anything else (refused, garbage) means the port is ours to take.
    private func probeHealth() -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        let done = DispatchSemaphore(value: 0)
        let box = ResultFlag()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data,
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                box.value = true
            }
            done.signal()
        }.resume()
        done.wait()
        return box.value
    }

    static let logPath = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/wren/serve.log")

    private func logHandle() throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(
            at: Self.logPath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.logPath.path) {
            fm.createFile(atPath: Self.logPath.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: Self.logPath)
        handle.seekToEndOfFile()
        return handle
    }
}

private final class ResultFlag: @unchecked Sendable {
    var value = false
}
