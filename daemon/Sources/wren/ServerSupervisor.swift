import Foundation

enum LocalServerStatus: Equatable, Sendable {
    case disabled
    case unavailable(String)
    case external
    case starting
    case running
    case crashed(String, retryIn: TimeInterval)
}

struct LocalServerState: Equatable, Sendable {
    var isEnabled: Bool
    var status: LocalServerStatus
}

protocol ProcessHandle: Sendable {
    var pid: pid_t { get }
    func terminateGroup()
    func killGroup()
}

protocol ProcessLaunching: Sendable {
    func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        logPath: String,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ProcessHandle
}

final class LiveProcessHandle: ProcessHandle {
    let pid: pid_t
    private let source: DispatchSourceProcess?

    init(pid: pid_t, source: DispatchSourceProcess?) {
        self.pid = pid
        self.source = source
    }

    func terminateGroup() {
        killpg(pid, SIGTERM)
    }

    func killGroup() {
        killpg(pid, SIGKILL)
    }
}

final class LiveProcessLauncher: ProcessLaunching {
    func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        logPath: String,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ProcessHandle {
        let logDir = (logPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: logDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fd = open(
            logPath,
            O_WRONLY | O_CREAT | O_APPEND,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, fd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, fd, STDERR_FILENO)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        posix_spawnattr_setflags(
            &attr,
            Int16(POSIX_SPAWN_SETPGROUP)
        )
        posix_spawnattr_setpgroup(&attr, 0)

        let argvStrings = [executable] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map {
            strdup($0)
        }
        argv.append(nil)
        defer {
            for ptr in argv where ptr != nil {
                free(ptr)
            }
        }

        var envStrings = [String]()
        for (k, v) in environment {
            envStrings.append("\(k)=\(v)")
        }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map {
            strdup($0)
        }
        envp.append(nil)
        defer {
            for ptr in envp where ptr != nil {
                free(ptr)
            }
        }

        var childPID: pid_t = 0
        let spawnStatus = posix_spawnp(
            &childPID,
            executable,
            &fileActions,
            &attr,
            argv,
            envp
        )
        guard spawnStatus == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnStatus) ?? .EIO)
        }

        let queue = DispatchQueue(label: "wren.supervisor.proc-\(childPID)")
        let source = DispatchSource.makeProcessSource(
            identifier: childPID,
            eventMask: .exit,
            queue: queue
        )

        source.setEventHandler {
            var status: Int32 = 0
            waitpid(childPID, &status, WNOHANG)
            source.cancel()
            onExit(status)
        }
        source.resume()

        return LiveProcessHandle(pid: childPID, source: source)
    }
}

@MainActor
final class ServerSupervisor {
    struct Dependencies {
        var launcher: any ProcessLaunching
        var probeHealth: @Sendable (String) async -> Bool
        var defaults: UserDefaults
        var isExecutableFile: @Sendable (String) -> Bool
        var readLastLogLine: @Sendable (String) -> String?
        var defaultScriptPath: @Sendable () -> String?
        var logPath: @Sendable () -> String
        var environment: @Sendable () -> [String: String]
        var sleepSeconds: @Sendable (TimeInterval) async -> Void
        var synchronousSleep: @Sendable (TimeInterval) -> Void

        init(
            launcher: any ProcessLaunching = LiveProcessLauncher(),
            probeHealth: @escaping @Sendable (String) async -> Bool = { host in
                await ServerSupervisor.liveProbeHealth(host: host)
            },
            defaults: UserDefaults = WrenDefaults.shared,
            isExecutableFile: @escaping @Sendable (String) -> Bool = { path in
                FileManager.default.isExecutableFile(atPath: path)
            },
            readLastLogLine: @escaping @Sendable (String) -> String? = { path in
                ServerSupervisor.liveReadLastLogLine(path: path)
            },
            defaultScriptPath: @escaping @Sendable () -> String? = {
                ServerSupervisor.findDefaultScriptPath()
            },
            logPath: @escaping @Sendable () -> String = {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return (home as NSString)
                    .appendingPathComponent("Library/Logs/wren/server.log")
            },
            environment: @escaping @Sendable () -> [String: String] = {
                ServerSupervisor.liveEnvironment()
            },
            sleepSeconds:
                @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    let nanos = UInt64(max(0, seconds) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                },
            synchronousSleep:
                @escaping @Sendable (TimeInterval) -> Void = { seconds in
                    let usecs = useconds_t(max(0, seconds) * 1_000_000)
                    usleep(usecs)
                }
        ) {
            self.launcher = launcher
            self.probeHealth = probeHealth
            self.defaults = defaults
            self.isExecutableFile = isExecutableFile
            self.readLastLogLine = readLastLogLine
            self.defaultScriptPath = defaultScriptPath
            self.logPath = logPath
            self.environment = environment
            self.sleepSeconds = sleepSeconds
            self.synchronousSleep = synchronousSleep
        }

        static var live: Dependencies { Dependencies() }
    }

    static let scriptKey = "server_script"
    static let runLocalServerKey = "run_local_server"

    var onChange: (@MainActor (LocalServerState) -> Void)?

    private(set) var state: LocalServerState {
        didSet {
            if state != oldValue {
                onChange?(state)
            }
        }
    }

    private let deps: Dependencies
    private var currentHost: String?
    private var activeChild: (any ProcessHandle)?
    private var supervisorTask: Task<Void, Never>?
    private var backoffIndex = 0
    private var generation: UInt64 = 0

    private static let backoffSequence: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    init(dependencies: Dependencies = .live) {
        self.deps = dependencies
        let isEnabled: Bool
        if dependencies.defaults.object(forKey: Self.runLocalServerKey) == nil {
            isEnabled = true
        } else {
            isEnabled = dependencies.defaults.bool(
                forKey: Self.runLocalServerKey
            )
        }
        self.state = LocalServerState(
            isEnabled: isEnabled,
            status: isEnabled ? .starting : .disabled
        )
    }

    func start(host: String) {
        currentHost = host
        restartSupervisor()
    }

    func setEnabled(_ enabled: Bool) {
        deps.defaults.set(enabled, forKey: Self.runLocalServerKey)
        state.isEnabled = enabled
        if !enabled {
            stopChild()
            supervisorTask?.cancel()
            supervisorTask = nil
            state.status = .disabled
        } else {
            backoffIndex = 0
            restartSupervisor()
        }
    }

    func hostChanged(_ host: String) {
        let oldHost = currentHost
        currentHost = host
        guard state.isEnabled else { return }

        let wasLoopback = oldHost.map(Self.isLoopbackHost) ?? false
        let isLoopback = Self.isLoopbackHost(host)

        if !isLoopback {
            stopChild()
            supervisorTask?.cancel()
            supervisorTask = nil
            state.status = .unavailable("Host '\(host)' is not loopback")
        } else if !wasLoopback {
            backoffIndex = 0
            restartSupervisor()
        }
    }

    func shutdown() {
        supervisorTask?.cancel()
        supervisorTask = nil
        guard let child = activeChild else { return }
        activeChild = nil

        child.terminateGroup()

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            let res = kill(child.pid, 0)
            if res != 0 && errno == ESRCH {
                return
            }
            deps.synchronousSleep(0.1)
        }

        child.killGroup()
    }

    // MARK: - Private details

    private func restartSupervisor() {
        supervisorTask?.cancel()
        generation &+= 1
        let gen = generation

        guard state.isEnabled else {
            stopChild()
            state.status = .disabled
            return
        }

        guard let host = currentHost else { return }

        guard Self.isLoopbackHost(host) else {
            stopChild()
            state.status = .unavailable("Host '\(host)' is not loopback")
            return
        }

        supervisorTask = Task { @MainActor [weak self] in
            await self?.runSupervisorLoop(generation: gen, host: host)
        }
    }

    private func stopChild() {
        guard let child = activeChild else { return }
        activeChild = nil
        child.terminateGroup()
    }

    private func runSupervisorLoop(
        generation gen: UInt64,
        host: String,
        isRetry: Bool = false
    ) async {
        guard gen == self.generation, !Task.isCancelled else { return }

        let scriptCandidate = deps.defaults.string(forKey: Self.scriptKey)
            ?? deps.defaultScriptPath()
        guard let script = scriptCandidate, deps.isExecutableFile(script) else {
            stopChild()
            let msg: String
            if let scriptCandidate {
                msg = "Script at '\(scriptCandidate)' is missing or not "
                    + "executable"
            } else {
                msg = "Server script not found"
            }
            state.status = .unavailable(msg)
            return
        }

        if !isRetry, await deps.probeHealth(host) {
            stopChild()
            state.status = .external

            while !Task.isCancelled && gen == self.generation {
                await deps.sleepSeconds(5.0)
                guard !Task.isCancelled && gen == self.generation else {
                    return
                }
                let healthy = await deps.probeHealth(host)
                if !healthy {
                    break
                }
            }
            guard !Task.isCancelled && gen == self.generation else { return }
        }

        // Spawn child server
        stopChild()
        state.status = .starting

        let exitTracker = ExitTracker()
        let handle: any ProcessHandle
        do {
            handle = try deps.launcher.spawn(
                executable: script,
                arguments: [],
                environment: deps.environment(),
                logPath: deps.logPath(),
                onExit: { [weak self, weak exitTracker] status in
                    exitTracker?.record(status: status)
                    Task { @MainActor [weak self] in
                        self?.handleChildExit(
                            generation: gen,
                            status: status
                        )
                    }
                }
            )
            activeChild = handle
        } catch {
            let delay = currentBackoff()
            advanceBackoff()
            state.status = .crashed(
                "Failed to spawn: \(error.localizedDescription)",
                retryIn: delay
            )
            await deps.sleepSeconds(delay)
            guard !Task.isCancelled && gen == self.generation else { return }
            await runSupervisorLoop(generation: gen, host: host)
            return
        }

        while !Task.isCancelled && gen == self.generation {
            if exitTracker.hasExited { return }
            if case .crashed = state.status { return }
            let ok = await deps.probeHealth(host)
            if exitTracker.hasExited { return }
            if case .crashed = state.status { return }
            if ok {
                break
            }
            await deps.sleepSeconds(1.0)
        }

        guard !Task.isCancelled && gen == self.generation else { return }
        if exitTracker.hasExited { return }
        if case .crashed = state.status { return }
        state.status = .running
        let resetTask = Task { @MainActor [weak self] in
            await self?.deps.sleepSeconds(60.0)
            guard !Task.isCancelled, let self, self.generation == gen else {
                return
            }
            if self.state.status == .running {
                self.backoffIndex = 0
            }
        }
        defer { resetTask.cancel() }

        while !Task.isCancelled && gen == self.generation {
            await deps.sleepSeconds(5.0)
            if exitTracker.hasExited { return }
            if case .crashed = state.status { return }
            _ = await deps.probeHealth(host)
        }
    }

    private func handleChildExit(generation gen: UInt64, status: Int32) {
        guard gen == self.generation, state.isEnabled else { return }
        activeChild = nil
        supervisorTask?.cancel()
        generation &+= 1
        let nextGen = generation

        let logTail = deps.readLastLogLine(deps.logPath())
        let reason = logTail ?? "exited with status \(status)"
        let delay = currentBackoff()
        advanceBackoff()

        state.status = .crashed(reason, retryIn: delay)

        supervisorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.deps.sleepSeconds(delay)
            guard !Task.isCancelled && nextGen == self.generation else {
                return
            }
            if let host = self.currentHost {
                await self.runSupervisorLoop(
                    generation: nextGen,
                    host: host,
                    isRetry: true
                )
            }
        }
    }

    private func currentBackoff() -> TimeInterval {
        let index = min(backoffIndex, Self.backoffSequence.count - 1)
        return Self.backoffSequence[index]
    }

    private func advanceBackoff() {
        if backoffIndex < Self.backoffSequence.count - 1 {
            backoffIndex += 1
        }
    }

    // MARK: - Helpers

    nonisolated static func isLoopbackHost(_ raw: String) -> Bool {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"]
        where host.lowercased().hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        while host.hasSuffix("/") { host.removeLast() }
        if host.hasPrefix("[") {
            if let closingBracket = host.firstIndex(of: "]") {
                let inside = String(
                    host[host.index(after: host.startIndex)..<closingBracket]
                )
                return inside == "::1"
            }
        }

        let hostPart: String
        if let colonIndex = host.lastIndex(of: ":") {
            hostPart = String(host[..<colonIndex])
        } else {
            hostPart = host
        }

        let lower = hostPart.lowercased()
        return lower == "127.0.0.1" || lower == "localhost" || lower == "::1"
    }

    nonisolated static func liveProbeHealth(host: String) async -> Bool {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString: String
        if clean.lowercased().hasPrefix("http://") ||
            clean.lowercased().hasPrefix("https://") {
            urlString = "\(clean)/health"
        } else {
            urlString = "http://\(clean)/health"
        }
        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    nonisolated static func liveReadLastLogLine(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    nonisolated static func liveEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let user = env["USER"] ?? ""
        let extraPaths = [
            "~/.local/bin",
            "~/.nix-profile/bin",
            "/etc/profiles/per-user/\(user)/bin",
            "/run/current-system/sw/bin",
            "/opt/homebrew/bin"
        ].map { ($0 as NSString).expandingTildeInPath }

        let existing = env["PATH"] ?? ""
        let combined = (extraPaths + [existing])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        env["PATH"] = combined
        return env
    }

    nonisolated static func findDefaultScriptPath() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("scripts/serve.sh").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

private final class ExitTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var exitStatus: Int32?

    var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    func record(status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        exited = true
        exitStatus = status
    }
}
