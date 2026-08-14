import Foundation
import XCTest
@testable import wren

final class DaemonManagerTests: XCTestCase {
    func testCompatibleMetaConnectsWithoutSpawning() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9321")!
        let probes = LockedArray<ProbeCall>()
        let launches = LockedValue(0)
        let manager = makeManager(
            endpoint: endpoint,
            probe: { url, token in
                probes.append(ProbeCall(endpoint: url, token: token))
                return .response(Self.compatibleMeta)
            },
            launch: { _ in
                launches.update { $0 += 1 }
                return TestManagedChild()
            }
        )
        let ready = expectation(description: "connected Wren ready")
        manager.onState = { state in
            if state.phase == .ready {
                ready.fulfill()
            }
        }

        manager.start()
        await fulfillment(of: [ready], timeout: 1)

        XCTAssertEqual(launches.value, 0)
        XCTAssertEqual(probes.value, [
            ProbeCall(endpoint: endpoint, token: "test-token"),
        ])
        XCTAssertEqual(manager.state.ownership, .connected)
        XCTAssertEqual(manager.state.endpoint, endpoint)
        XCTAssertEqual(manager.state.meta, Self.compatibleMeta)
        XCTAssertNil(manager.state.libraryLocation)
        XCTAssertNil(manager.state.logLocation)
    }

    func testAuthenticatedArbitraryJSONIsAnIdentityFailure() throws {
        let endpoint = URL(string: "http://127.0.0.1:9321/meta")!
        let response = try XCTUnwrap(HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil))

        let result = DaemonManager.classifyProbe(
            expectedURL: endpoint,
            data: Data("{}".utf8),
            response: response,
            error: nil)

        guard case .response(let meta) = result else {
            return XCTFail("expected identity-shaped probe result")
        }
        XCTAssertEqual(meta.service, "unknown")
        XCTAssertThrowsError(
            try DaemonClient.validateIdentity(meta)
        ) { error in
            guard case .identity(let service) = error as? DaemonError else {
                return XCTFail("expected identity failure, got \(error)")
            }
            XCTAssertEqual(service, "unknown")
        }
    }

    func testOnlyRefusalPermitsSpawn() async throws {
        let failures: [(DaemonManager.ProbeResult,
                        DaemonManager.Failure.Kind)] = [
            (.authorization("bad token"), .authorization),
            (.originAccess("origin not allowed"), .originAccess),
            (.response(Self.meta(service: "other")), .identity),
            (.response(Self.meta(protocolVersion: 1)), .compatibility),
            (.response(Self.meta(capabilities: [.stateV2])),
             .compatibility),
            (.transport("timed out"), .transport),
            (.decoding("malformed /meta"), .decoding),
        ]

        for (probeResult, expectedKind) in failures {
            let launches = LockedValue(0)
            let manager = makeManager(
                probe: { _, _ in probeResult },
                launch: { _ in
                    launches.update { $0 += 1 }
                    return TestManagedChild()
                }
            )
            let failed = expectation(
                description: "\(expectedKind) becomes visible"
            )
            manager.onState = { state in
                if state.phase == .failed {
                    failed.fulfill()
                }
            }

            manager.start()
            await fulfillment(of: [failed], timeout: 1)

            XCTAssertEqual(launches.value, 0)
            XCTAssertEqual(manager.state.error?.kind, expectedKind)
            XCTAssertFalse(
                manager.state.error?.canResetInvalidSettings == true)
            XCTAssertTrue(manager.state.error?.canRetry == true)
        }
    }

    func testRefusalSpawnsOneManagedChildAtExactEndpoint() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9322")!
        let probeResults = LockedArray<DaemonManager.ProbeResult>([
            .refused,
            .response(Self.compatibleMeta),
        ])
        let launchArguments = LockedArray<[String]>()
        let manager = makeManager(
            endpoint: endpoint,
            probe: { _, _ in probeResults.removeFirst() },
            launch: { arguments in
                launchArguments.append(arguments)
                return TestManagedChild()
            }
        )
        let ready = expectation(description: "managed Wren ready")
        manager.onState = { state in
            if state.phase == .ready {
                ready.fulfill()
            }
        }

        manager.start()
        await fulfillment(of: [ready], timeout: 1)

        let arguments = try XCTUnwrap(launchArguments.value.first)
        XCTAssertEqual(launchArguments.value.count, 1)
        XCTAssertEqual(arguments, [
            "/test/resources/server/serve.py",
            "--local-player", "client",
            "-b", "qwentts",
            "--qwentts-bin", "/test/resources/engine/tts-server",
            "--qwentts-model",
            "/test/support/models/qwen-talker-1.7b-base-Q8_0.gguf",
            "--qwentts-codec",
            "/test/support/models/qwen-tokenizer-12hz-Q8_0.gguf",
            "--voices-dir", "/test/support/voices",
            "--config", "/test/support/config.json",
            "--initial-voice", "c3po_god",
            "--host", "127.0.0.1",
            "--port", "9322",
            "--token", "test-token",
        ])
        XCTAssertEqual(manager.state.ownership, .managed)
        XCTAssertEqual(
            manager.state.libraryLocation?.path,
            "/test/support/voices"
        )
    }


    func testManagedShutdownTerminatesBeforeReturning() async {
        let probes = LockedArray<DaemonManager.ProbeResult>([
            .refused,
            .response(Self.compatibleMeta),
        ])
        let child = TestManagedChild()
        let manager = makeManager(
            probe: { _, _ in probes.removeFirst() },
            launch: { _ in child })
        let ready = expectation(description: "managed ready")
        manager.onState = { state in
            if state.phase == .ready {
                ready.fulfill()
            }
        }
        manager.start()
        await fulfillment(of: [ready], timeout: 1)

        manager.shutdown()

        XCTAssertEqual(child.terminateCount, 1)
        XCTAssertFalse(child.isRunning)
    }
    func testExistingSettingsOmitBootstrapVoiceHint() {
        let paths = WrenPaths(
            resources: URL(fileURLWithPath: "/bundle/resources"),
            appSupport: URL(fileURLWithPath: "/user/support")
        )

        XCTAssertEqual(
            DaemonManager.serveArguments(
                paths: paths,
                settingsExist: true
            ),
            [
                "/bundle/resources/server/serve.py",
                "--local-player", "client",
                "-b", "qwentts",
                "--qwentts-bin",
                "/bundle/resources/engine/tts-server",
                "--qwentts-model",
                "/user/support/models/qwen-talker-1.7b-base-Q8_0.gguf",
                "--qwentts-codec",
                "/user/support/models/qwen-tokenizer-12hz-Q8_0.gguf",
                "--voices-dir", "/user/support/voices",
                "--config", "/user/support/config.json",
            ]
        )
    }

    func testProvisionerDoesNotRecreateRetiredFlatVoiceBackups()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = WrenPaths(
            resources: root.appendingPathComponent(
                "resources",
                isDirectory: true),
            appSupport: root.appendingPathComponent(
                "support",
                isDirectory: true))
        try FileManager.default.createDirectory(
            at: paths.bundledVoices,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.voices,
            withIntermediateDirectories: true)
        for id in ["c3po_god", "wintermute"] {
            try Data("audio".utf8).write(
                to: paths.bundledVoices
                    .appendingPathComponent("\(id).wav"))
            try Data("transcript".utf8).write(
                to: paths.bundledVoices
                    .appendingPathComponent("\(id).txt"))
        }
        try FileManager.default.createDirectory(
            at: paths.voices.appendingPathComponent(
                "c3po_god",
                isDirectory: true),
            withIntermediateDirectories: true)

        try Provisioner(paths: paths, progress: { _ in }).seedVoices()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.voices
                .appendingPathComponent("c3po_god.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.voices
                .appendingPathComponent("c3po_god.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.voices
                .appendingPathComponent("wintermute.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.voices
                .appendingPathComponent("wintermute.txt").path))
    }

    func testConnectedLifecycleActionsAreNonDestructive() async throws {
        let paths = try makeTemporaryPaths()
        defer {
            try? FileManager.default.removeItem(at: paths.appSupport)
        }
        let legacyConfig = Data("legacy migration backup".utf8)
        let v2Settings = Data("{ malformed v2".utf8)
        try legacyConfig.write(to: paths.configFile)
        try v2Settings.write(to: paths.settingsFile)
        let launches = LockedValue(0)
        let resets = LockedValue(0)
        let manager = makeManager(
            paths: paths,
            probe: { _, _ in .response(Self.compatibleMeta) },
            reset: { resetPaths in
                resets.update { $0 += 1 }
                try DaemonManager.Dependencies.live
                    .resetInvalidSettings(resetPaths)
            },
            launch: { _ in
                launches.update { $0 += 1 }
                return TestManagedChild()
            }
        )
        let ready = expectation(description: "connected")
        let unsupported = expectation(description: "unsupported actions")
        unsupported.expectedFulfillmentCount = 3
        manager.onState = { state in
            if state.phase == .ready && state.error == nil {
                ready.fulfill()
            }
            if state.error?.kind == .unsupportedAction {
                unsupported.fulfill()
            }
        }

        manager.start()
        await fulfillment(of: [ready], timeout: 1)
        manager.restart()
        manager.resetInvalidSettings()
        manager.retry()
        await fulfillment(of: [unsupported], timeout: 1)
        manager.shutdown()

        XCTAssertEqual(launches.value, 0)
        XCTAssertEqual(resets.value, 0)
        XCTAssertEqual(
            try Data(contentsOf: paths.configFile),
            legacyConfig
        )
        XCTAssertEqual(
            try Data(contentsOf: paths.settingsFile),
            v2Settings
        )
        XCTAssertEqual(manager.state.ownership, .connected)
    }

    func testManagedResetQuarantinesConfigurationAndReachesReady()
        async throws {
        let paths = try makeTemporaryPaths()
        defer {
            try? FileManager.default.removeItem(at: paths.appSupport)
        }
        let legacyConfig = Data("legacy migration backup".utf8)
        let v2Settings = Data("{ malformed v2".utf8)
        try legacyConfig.write(to: paths.configFile)
        try v2Settings.write(to: paths.settingsFile)
        let probes = LockedArray<DaemonManager.ProbeResult>([
            .refused,
            .response(Self.compatibleMeta),
            .response(Self.compatibleMeta),
        ])
        let children = LockedArray<TestManagedChild>()
        let launchArguments = LockedArray<[String]>()
        let resets = LockedValue(0)
        let readyOne = expectation(description: "initial managed ready")
        let readyTwo = expectation(description: "reset managed ready")
        let readyCount = LockedValue(0)
        let manager = makeManager(
            paths: paths,
            probe: { _, _ in probes.removeFirst() },
            reset: { resetPaths in
                resets.update { $0 += 1 }
                try DaemonManager.Dependencies.live
                    .resetInvalidSettings(resetPaths)
            },
            launch: { arguments in
                launchArguments.append(arguments)
                let child = TestManagedChild()
                children.append(child)
                return child
            }
        )
        manager.onState = { state in
            guard state.phase == .ready else { return }
            readyCount.update { $0 += 1 }
            if readyCount.value == 1 {
                readyOne.fulfill()
            } else if readyCount.value == 2 {
                readyTwo.fulfill()
            }
        }

        manager.start()
        await fulfillment(of: [readyOne], timeout: 1)
        manager.resetInvalidSettings()
        await fulfillment(of: [readyTwo], timeout: 1)

        XCTAssertEqual(resets.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.settingsFile.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.configFile.path))
        let backups = try FileManager.default.contentsOfDirectory(
            at: paths.appSupport,
            includingPropertiesForKeys: nil)
        let settingsBackup = try XCTUnwrap(backups.first {
            $0.lastPathComponent.hasPrefix(
                ".settings.json.invalid-")
        })
        let configBackup = try XCTUnwrap(backups.first {
            $0.lastPathComponent.hasPrefix(
                ".config.json.invalid-")
        })
        XCTAssertEqual(try Data(contentsOf: settingsBackup), v2Settings)
        XCTAssertEqual(try Data(contentsOf: configBackup), legacyConfig)
        XCTAssertEqual(children.value.count, 2)
        XCTAssertEqual(children.value[0].terminateCount, 1)
        XCTAssertEqual(children.value[1].terminateCount, 0)
        XCTAssertFalse(
            launchArguments.value[0].contains("--initial-voice"))
        XCTAssertTrue(
            launchArguments.value[1].contains("--initial-voice"))
        XCTAssertEqual(manager.state.ownership, .managed)
    }

    func testManagedResetSurfacesQuarantineErrorWithoutRestarting()
        async throws {
        let probes = LockedArray<DaemonManager.ProbeResult>([
            .refused,
            .response(Self.compatibleMeta),
        ])
        let children = LockedArray<TestManagedChild>()
        let ready = expectation(description: "initial managed ready")
        let failed = expectation(description: "reset quarantine failed")
        let manager = makeManager(
            probe: { _, _ in probes.removeFirst() },
            reset: { _ in
                throw NSError(domain: "reset-test", code: 23)
            },
            launch: { _ in
                let child = TestManagedChild()
                children.append(child)
                return child
            }
        )
        manager.onState = { state in
            if state.phase == .ready {
                ready.fulfill()
            }
            if state.error?.kind == .resetInvalidSettings {
                failed.fulfill()
            }
        }

        manager.start()
        await fulfillment(of: [ready], timeout: 1)
        manager.resetInvalidSettings()
        await fulfillment(of: [failed], timeout: 1)

        XCTAssertEqual(children.value.count, 1)
        XCTAssertEqual(children.value[0].terminateCount, 0)
        XCTAssertEqual(manager.state.phase, .failed)
        XCTAssertEqual(
            manager.state.error?.kind,
            .resetInvalidSettings
        )
        XCTAssertTrue(
            manager.state.error?.message.contains("reset-test") == true
        )
    }

    func testManagedCrashBackoffOpensCircuitAfterThreeRapidExits()
        async throws {
        let scheduler = TestManagerScheduler()
        let clock = LockedValue(Date(timeIntervalSince1970: 100))
        let probes = LockedArray<DaemonManager.ProbeResult>([
            .refused, .response(Self.compatibleMeta),
            .refused, .response(Self.compatibleMeta),
            .refused, .response(Self.compatibleMeta),
        ])
        let children = LockedArray<TestManagedChild>()
        let readyOne = expectation(description: "initial ready")
        let readyTwo = expectation(description: "first recovery ready")
        let readyThree = expectation(description: "second recovery ready")
        let recoveryOne = expectation(description: "one second backoff")
        let recoveryTwo = expectation(description: "two second backoff")
        let circuit = expectation(description: "circuit open")
        let readyCount = LockedValue(0)
        let manager = makeManager(
            probe: { _, _ in probes.removeFirst() },
            now: { clock.value },
            schedule: scheduler.schedule,
            launch: { _ in
                let child = TestManagedChild()
                children.append(child)
                return child
            }
        )
        manager.onState = { state in
            if state.phase == .ready {
                readyCount.update { $0 += 1 }
                switch readyCount.value {
                case 1: readyOne.fulfill()
                case 2: readyTwo.fulfill()
                case 3: readyThree.fulfill()
                default: break
                }
            }
            if state.phase == .recovering(attempt: 1, delay: 1) {
                recoveryOne.fulfill()
            }
            if state.phase == .recovering(attempt: 2, delay: 2) {
                recoveryTwo.fulfill()
            }
            if state.error?.kind == .circuitOpen {
                circuit.fulfill()
            }
        }

        manager.start()
        await fulfillment(of: [readyOne], timeout: 1)
        children.value[0].crash()
        await fulfillment(of: [recoveryOne], timeout: 1)
        XCTAssertEqual(scheduler.runNext(), 1)
        await fulfillment(of: [readyTwo], timeout: 1)

        children.value[1].crash()
        await fulfillment(of: [recoveryTwo], timeout: 1)
        XCTAssertEqual(scheduler.runNext(), 2)
        await fulfillment(of: [readyThree], timeout: 1)

        children.value[2].crash()
        await fulfillment(of: [circuit], timeout: 1)

        XCTAssertEqual(children.value.count, 3)
        XCTAssertEqual(manager.state.phase, .failed)
        XCTAssertEqual(manager.state.ownership, .managed)
        XCTAssertEqual(manager.state.error?.kind, .circuitOpen)
        XCTAssertFalse(
            manager.state.error?.canResetInvalidSettings == true)
        XCTAssertTrue(manager.state.error?.message.contains(
            DaemonManager.logPath.path
        ) == true)
        XCTAssertNil(scheduler.runNext())
    }

    func testRetryRecoversAnOpenManagedCircuit() async throws {
        let scheduler = TestManagerScheduler()
        let probes = LockedArray<DaemonManager.ProbeResult>([
            .refused, .response(Self.compatibleMeta),
            .refused, .response(Self.compatibleMeta),
            .refused, .response(Self.compatibleMeta),
            .refused, .response(Self.compatibleMeta),
        ])
        let children = LockedArray<TestManagedChild>()
        let readyOne = expectation(description: "initial ready")
        let readyTwo = expectation(description: "first recovery ready")
        let readyThree = expectation(description: "second recovery ready")
        let recoveryOne = expectation(description: "first recovery")
        let recoveryTwo = expectation(description: "second recovery")
        let circuit = expectation(description: "circuit open")
        let recovered = expectation(description: "retry ready")
        let readyCount = LockedValue(0)
        let manager = makeManager(
            probe: { _, _ in probes.removeFirst() },
            schedule: scheduler.schedule,
            launch: { _ in
                let child = TestManagedChild()
                children.append(child)
                return child
            }
        )
        manager.onState = { state in
            if state.phase == .ready {
                readyCount.update { $0 += 1 }
                switch readyCount.value {
                case 1: readyOne.fulfill()
                case 2: readyTwo.fulfill()
                case 3: readyThree.fulfill()
                case 4: recovered.fulfill()
                default: break
                }
            }
            if state.phase == .recovering(attempt: 1, delay: 1) {
                recoveryOne.fulfill()
            }
            if state.phase == .recovering(attempt: 2, delay: 2) {
                recoveryTwo.fulfill()
            }
            if state.error?.kind == .circuitOpen {
                circuit.fulfill()
            }
        }

        manager.start()
        await fulfillment(of: [readyOne], timeout: 1)
        children.value[0].crash()
        await fulfillment(of: [recoveryOne], timeout: 1)
        _ = scheduler.runNext()
        await fulfillment(of: [readyTwo], timeout: 1)

        children.value[1].crash()
        await fulfillment(of: [recoveryTwo], timeout: 1)
        _ = scheduler.runNext()
        await fulfillment(of: [readyThree], timeout: 1)

        children.value[2].crash()
        await fulfillment(of: [circuit], timeout: 1)
        manager.retry()
        await fulfillment(of: [recovered], timeout: 1)

        XCTAssertEqual(children.value.count, 4)
        XCTAssertEqual(manager.state.phase, .ready)
        XCTAssertEqual(manager.state.ownership, .managed)
        XCTAssertNil(manager.state.error)
    }

    private static let compatibleMeta = meta()

    private static func meta(
        service: String = "wren",
        protocolVersion: Int = 2,
        capabilities: [DaemonCapability] = [
            .stateV2,
            .voiceList,
            .voiceActivate,
            .settingsV2,
            .segmentPlayer,
        ]
    ) -> MetaResponse {
        MetaResponse(
            service: service,
            protocolVersion: protocolVersion,
            instanceID: "manager-test",
            startedAt: "2026-08-11T00:00:00Z",
            capabilities: capabilities
        )
    }

    private func makeManager(
        paths: WrenPaths = WrenPaths(
            resources: URL(fileURLWithPath: "/test/resources"),
            appSupport: URL(fileURLWithPath: "/test/support")
        ),
        endpoint: URL = URL(string: "http://127.0.0.1:9320")!,
        probe: @escaping @Sendable (
            URL,
            String?
        ) -> DaemonManager.ProbeResult,
        reset: @escaping @Sendable (WrenPaths) throws -> Void = { _ in },
        now: @escaping @Sendable () -> Date = {
            Date(timeIntervalSince1970: 100)
        },
        schedule: @escaping DaemonManager.Dependencies.Schedule = {
            _, work in work()
        },
        launch: @escaping @Sendable (
            [String]
        ) throws -> TestManagedChild
    ) -> DaemonManager {
        let dependencies = DaemonManager.Dependencies(
            probeMeta: probe,
            canSpawn: { _ in true },
            provision: { _, progress in progress(.ready) },
            launch: { _, arguments, _, _, onExit in
                let child = try launch(arguments)
                child.onExit = onExit
                return child
            },
            openLog: { FileHandle.nullDevice },
            resetInvalidSettings: reset,
            now: now,
            sleep: { _ in },
            schedule: schedule
        )
        return DaemonManager(
            paths: paths,
            baseURL: endpoint,
            token: "test-token",
            dependencies: dependencies
        )
    }

    private func makeTemporaryPaths() throws -> WrenPaths {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
        return WrenPaths(
            resources: URL(fileURLWithPath: "/test/resources"),
            appSupport: appSupport
        )
    }
}

private struct ProbeCall: Equatable {
    let endpoint: URL
    let token: String?
}

private final class TestManagedChild: ManagedDaemonChild,
    @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var exitHandler: (@Sendable () -> Void)?
    private var terminations = 0

    var onExit: (@Sendable () -> Void)? {
        get { lock.withLock { exitHandler } }
        set { lock.withLock { exitHandler = newValue } }
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var terminateCount: Int {
        lock.withLock { terminations }
    }

    func terminate() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            terminations += 1
            running = false
            return exitHandler
        }
        handler?()
    }

    func crash() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            running = false
            return exitHandler
        }
        handler?()
    }
}

private final class TestManagerScheduler: @unchecked Sendable {
    typealias Job = (
        delay: TimeInterval,
        work: @Sendable () -> Void
    )

    private let jobs = LockedArray<Job>()

    var schedule: DaemonManager.Dependencies.Schedule {
        { [jobs] delay, work in
            jobs.append((delay, work))
        }
    }

    var pendingCount: Int { jobs.value.count }

    func runNext() -> TimeInterval? {
        guard let job = jobs.removeFirstIfPresent() else { return nil }
        job.work()
        return job.delay
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func update(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element]

    init(_ elements: [Element] = []) {
        storage = elements
    }

    var value: [Element] {
        lock.withLock { storage }
    }

    func append(_ element: Element) {
        lock.withLock { storage.append(element) }
    }

    func removeFirst() -> Element {
        lock.withLock { storage.removeFirst() }
    }

    func removeFirstIfPresent() -> Element? {
        lock.withLock {
            guard !storage.isEmpty else { return nil }
            return storage.removeFirst()
        }
    }
}
