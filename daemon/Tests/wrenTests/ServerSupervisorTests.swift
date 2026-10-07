import Foundation
import XCTest
@testable import wren

private final class TestProcessHandle: ProcessHandle, @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private(set) var terminateGroupCount = 0
    private(set) var killGroupCount = 0

    init(pid: pid_t = 1234) {
        self.pid = pid
    }

    func terminateGroup() {
        lock.lock()
        defer { lock.unlock() }
        terminateGroupCount += 1
    }

    func killGroup() {
        lock.lock()
        defer { lock.unlock() }
        killGroupCount += 1
    }
}

private final class TestLauncher: ProcessLaunching, @unchecked Sendable {
    struct SpawnCall {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var logPath: String
    }

    private let lock = NSLock()
    var spawnError: Error?
    var nextPID: pid_t = 2000
    private(set) var calls: [SpawnCall] = []
    private(set) var handles: [TestProcessHandle] = []
    private var exitCallbacks: [pid_t: @Sendable (Int32) -> Void] = [:]

    func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        logPath: String,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ProcessHandle {
        lock.lock()
        defer { lock.unlock() }
        if let error = spawnError {
            throw error
        }
        calls.append(
            SpawnCall(
                executable: executable,
                arguments: arguments,
                environment: environment,
                logPath: logPath
            )
        )
        let pid = nextPID
        nextPID += 1
        let handle = TestProcessHandle(pid: pid)
        handles.append(handle)
        exitCallbacks[pid] = onExit
        return handle
    }

    func triggerExit(pid: pid_t, status: Int32) {
        let callback: (@Sendable (Int32) -> Void)?
        lock.lock()
        callback = exitCallbacks[pid]
        lock.unlock()
        callback?(status)
    }

    func triggerLastExit(status: Int32) {
        lock.lock()
        let pid = handles.last?.pid
        lock.unlock()
        if let pid {
            triggerExit(pid: pid, status: status)
        }
    }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: Bool] = [:]
    private var defaultResponse = false
    private(set) var probeHistory: [String] = []

    init(defaultResponse: Bool = false) {
        self.defaultResponse = defaultResponse
    }

    func setHealthy(_ host: String, _ healthy: Bool) {
        lock.lock()
        defer { lock.unlock() }
        responses[host] = healthy
    }

    func setDefault(_ healthy: Bool) {
        lock.lock()
        defer { lock.unlock() }
        defaultResponse = healthy
    }

    func probe(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        probeHistory.append(host)
        return responses[host] ?? defaultResponse
    }
}

private final class SleepBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sleeps: [TimeInterval] = []

    func sleep(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        sleeps.append(interval)
    }
}

@MainActor
final class ServerSupervisorTests: XCTestCase {
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "wren-supervisor-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func waitUntil(
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), "Condition timed out", line: line)
    }

    func testExternalAdoptionWithoutSpawn() async throws {
        let launcher = TestLauncher()
        let probe = ProbeBox(defaultResponse: true)
        let sleepBox = SleepBox()

        var deps = ServerSupervisor.Dependencies.live
        deps.defaults = testDefaults
        deps.launcher = launcher
        deps.probeHealth = { host in probe.probe(host) }
        deps.sleepSeconds = { s in sleepBox.sleep(s) }
        deps.isExecutableFile = { _ in true }
        deps.defaultScriptPath = { "/mock/scripts/serve.sh" }

        let supervisor = ServerSupervisor(dependencies: deps)
        var observed: [LocalServerState] = []
        supervisor.onChange = { observed.append($0) }

        supervisor.start(host: "127.0.0.1:8765")

        try await waitUntil { supervisor.state.status == .external }

        XCTAssertEqual(launcher.calls.count, 0)
        XCTAssertEqual(supervisor.state.status, .external)
        XCTAssertTrue(supervisor.state.isEnabled)
    }

    func testStartingToRunningFlow() async throws {
        let launcher = TestLauncher()
        let probe = ProbeBox(defaultResponse: false)
        let sleepBox = SleepBox()

        var deps = ServerSupervisor.Dependencies.live
        deps.defaults = testDefaults
        deps.launcher = launcher
        deps.probeHealth = { host in probe.probe(host) }
        deps.sleepSeconds = { s in sleepBox.sleep(s) }
        deps.isExecutableFile = { _ in true }
        deps.defaultScriptPath = { "/mock/scripts/serve.sh" }

        let supervisor = ServerSupervisor(dependencies: deps)
        supervisor.start(host: "127.0.0.1:8765")

        try await waitUntil { launcher.calls.count == 1 }
        XCTAssertEqual(supervisor.state.status, .starting)

        probe.setDefault(true)

        try await waitUntil { supervisor.state.status == .running }
        XCTAssertEqual(supervisor.state.status, .running)
    }

    func testCrashBackoffSequenceAndReset() async throws {
        let launcher = TestLauncher()
        let probe = ProbeBox(defaultResponse: false)
        let sleepBox = SleepBox()

        var deps = ServerSupervisor.Dependencies.live
        deps.defaults = testDefaults
        deps.launcher = launcher
        deps.probeHealth = { host in probe.probe(host) }
        deps.sleepSeconds = { s in
            sleepBox.sleep(s)
            let ms = s == 60.0 ? 5 : Int(s * 50)
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        }
        deps.isExecutableFile = { _ in true }
        deps.defaultScriptPath = { "/mock/scripts/serve.sh" }
        deps.readLastLogLine = { _ in "Fatal error: out of memory" }

        let supervisor = ServerSupervisor(dependencies: deps)
        supervisor.start(host: "127.0.0.1:8765")
        try await waitUntil(line: #line) { launcher.calls.count == 1 }
        try await waitUntil(line: #line) {
            supervisor.state.status == .starting
        }
        launcher.triggerLastExit(status: 1)
        try await waitUntil(line: #line) {
            if case .crashed(let reason, let retry) = supervisor.state.status {
                return reason == "Fatal error: out of memory" && retry == 1.0
            }
            return false
        }

        // Wait for retry spawn #2
        try await waitUntil(line: #line) { launcher.calls.count == 2 }
        try await waitUntil(line: #line) {
            supervisor.state.status == .starting
        }
        // Crash 2: backoff should be 2s
        launcher.triggerLastExit(status: 1)
        try await waitUntil(line: #line) {
            if case .crashed(_, let retry) = supervisor.state.status {
                return retry == 2.0
            }
            return false
        }

        // Wait for retry spawn #3
        try await waitUntil(line: #line) { launcher.calls.count == 3 }
        try await waitUntil(line: #line) {
            supervisor.state.status == .starting
        }
        // Crash 3: backoff should be 4s
        launcher.triggerLastExit(status: 1)
        try await waitUntil(line: #line) {
            if case .crashed(_, let retry) = supervisor.state.status {
                return retry == 4.0
            }
            return false
        }

        // Wait for spawn #4, make it healthy -> running
        try await waitUntil(line: #line) { launcher.calls.count == 4 }
        probe.setDefault(true)
        try await waitUntil(line: #line) { supervisor.state.status == .running }

        try await waitUntil(line: #line) { sleepBox.sleeps.contains(60.0) }
        // Wait until backoff resets to index 0
        try await Task.sleep(nanoseconds: 50_000_000)
        probe.setDefault(false)
        launcher.triggerLastExit(status: 1)
        try await waitUntil(line: #line) {
            if case .crashed(_, let retry) = supervisor.state.status {
                return retry == 1.0
            }
            return false
        }
    }

    func testDisableKillsOwnChildButNotExternal() async throws {
        let launcher = TestLauncher()
        let probe = ProbeBox(defaultResponse: false)
        let sleepBox = SleepBox()

        var deps = ServerSupervisor.Dependencies.live
        deps.defaults = testDefaults
        deps.launcher = launcher
        deps.probeHealth = { host in probe.probe(host) }
        deps.sleepSeconds = { s in sleepBox.sleep(s) }
        deps.isExecutableFile = { _ in true }
        deps.defaultScriptPath = { "/mock/scripts/serve.sh" }

        let supervisor = ServerSupervisor(dependencies: deps)
        supervisor.start(host: "127.0.0.1:8765")

        try await waitUntil { launcher.calls.count == 1 }
        let handle = launcher.handles[0]

        supervisor.setEnabled(false)
        XCTAssertEqual(supervisor.state.status, .disabled)
        XCTAssertFalse(supervisor.state.isEnabled)
        XCTAssertEqual(handle.terminateGroupCount, 1)

        // Now test external: enable, probe is true
        probe.setDefault(true)
        supervisor.setEnabled(true)
        try await waitUntil { supervisor.state.status == .external }

        // Disabling external server must NOT terminate launcher
        let prevTerminates = launcher.handles.map(\.terminateGroupCount)
        supervisor.setEnabled(false)
        XCTAssertEqual(supervisor.state.status, .disabled)
        XCTAssertEqual(
            launcher.handles.map(\.terminateGroupCount),
            prevTerminates
        )
    }

    func testNonLoopbackUnavailable() async throws {
        let launcher = TestLauncher()
        let probe = ProbeBox(defaultResponse: false)

        var deps = ServerSupervisor.Dependencies.live
        deps.defaults = testDefaults
        deps.launcher = launcher
        deps.probeHealth = { host in probe.probe(host) }
        deps.isExecutableFile = { _ in true }
        deps.defaultScriptPath = { "/mock/scripts/serve.sh" }

        let supervisor = ServerSupervisor(dependencies: deps)
        supervisor.start(host: "192.168.1.50:8765")

        try await waitUntil {
            if case .unavailable(let msg) = supervisor.state.status {
                return msg.contains("not loopback")
            }
            return false
        }
        XCTAssertEqual(launcher.calls.count, 0)
    }

    func testHostChangeStopsChild() async throws {
        let launcher = TestLauncher()
        let probe = ProbeBox(defaultResponse: false)
        let sleepBox = SleepBox()

        var deps = ServerSupervisor.Dependencies.live
        deps.defaults = testDefaults
        deps.launcher = launcher
        deps.probeHealth = { host in probe.probe(host) }
        deps.sleepSeconds = { s in sleepBox.sleep(s) }
        deps.isExecutableFile = { _ in true }
        deps.defaultScriptPath = { "/mock/scripts/serve.sh" }

        let supervisor = ServerSupervisor(dependencies: deps)
        supervisor.start(host: "127.0.0.1:8765")

        try await waitUntil { launcher.calls.count == 1 }
        let handle = launcher.handles[0]

        // Switch to remote non-loopback host
        supervisor.hostChanged("remote.box:8765")

        XCTAssertEqual(handle.terminateGroupCount, 1)
        if case .unavailable(let msg) = supervisor.state.status {
            XCTAssertTrue(msg.contains("not loopback"))
        } else {
            XCTFail("Expected unavailable status")
        }
    }
}
