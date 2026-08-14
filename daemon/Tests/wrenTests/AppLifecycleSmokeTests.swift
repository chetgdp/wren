import AppKit
import Foundation
import XCTest
@testable import wren

final class DaemonManagerOwnershipSmokeTests: XCTestCase {
    func testCleanQuitTerminatesManagedChild() async throws {
        let childStopped = expectation(description: "managed child stopped")
        let child = FakeManagedChild {
            childStopped.fulfill()
        }
        let spawned = expectation(description: "child spawned")
        let manager = makeManager(probeResult: .refused) {
            spawned.fulfill()
            return child
        }
        let stateChanged = expectation(description: "manager is ready")
        manager.onState = { state in
            if state.phase == .ready && state.ownership == .managed {
                stateChanged.fulfill()
            }
        }

        manager.start()
        await fulfillment(of: [spawned, stateChanged], timeout: 1)
        manager.shutdown()
        await fulfillment(of: [childStopped], timeout: 1)

        XCTAssertEqual(child.terminateCount, 1)
        XCTAssertFalse(child.isRunning)
    }

    func testCleanQuitDoesNotTerminateConnectedDaemon() async throws {
        let launches = LockedInt()
        let child = FakeManagedChild()
        let manager = makeManager(probeResult: .response(Self.meta)) {
            launches.increment()
            return child
        }
        let connected = expectation(description: "daemon connected")
        manager.onState = { state in
            if state.phase == .ready && state.ownership == .connected {
                connected.fulfill()
            }
        }

        manager.start()
        await fulfillment(of: [connected], timeout: 1)
        manager.shutdown()

        XCTAssertEqual(launches.value, 0)
        XCTAssertEqual(child.terminateCount, 0)
        XCTAssertTrue(child.isRunning)
    }

    private static let meta = MetaResponse(
        service: "wren",
        protocolVersion: 2,
        instanceID: "ownership-smoke",
        startedAt: "2026-08-11T00:00:00Z",
        capabilities: [
            .stateV2,
            .voiceList,
            .voiceActivate,
            .settingsV2,
            .segmentPlayer,
        ]
    )

    private func makeManager(
        probeResult: DaemonManager.ProbeResult,
        launch: @escaping @Sendable () throws -> ManagedDaemonChild
    ) -> DaemonManager {
        let paths = WrenPaths(
            resources: URL(fileURLWithPath: "/test/resources"),
            appSupport: URL(fileURLWithPath: "/test/support")
        )
        let probes = LockedInt()
        let dependencies = DaemonManager.Dependencies(
            probeMeta: { _, _ in
                probes.increment()
                if probeResult == .refused && probes.value > 1 {
                    return .response(Self.meta)
                }
                return probeResult
            },
            canSpawn: { _ in true },
            provision: { _, _ in },
            launch: { _, _, _, _, _ in try launch() },
            openLog: { FileHandle.nullDevice },
            resetInvalidSettings: { _ in },
            now: { Date(timeIntervalSince1970: 100) },
            sleep: { _ in },
            schedule: { _, work in work() }
        )
        return DaemonManager(
            paths: paths,
            baseURL: URL(string: "http://127.0.0.1:1")!,
            token: "ownership-token",
            dependencies: dependencies
        )
    }
}

final class SegmentPlayerSmokeTests: XCTestCase {
    func testLocalSegmentPauseResumeAndStop() async throws {
        let segmentRequested = expectation(description: "segment requested")
        var responseCount = 0
        let bytes = Data([0x52, 0x49, 0x46, 0x46])
        let server = try StubServer(respondData: { request in
            responseCount += 1
            if responseCount == 1 {
                segmentRequested.fulfill()
                return StubServer.Response(
                    status: 200,
                    headers: [
                        "Content-Type": "audio/wav",
                        "X-Epoch": "7",
                        "X-Seq": "1",
                    ],
                    body: bytes
                )
            }
            return StubServer.Response(
                status: 404,
                headers: [:],
                body: Data()
            )
        })
        defer { server.stop() }

        let audio = FakeSegmentAudioOutput(testCase: self)
        let player = SegmentPlayer(
            base: URL(string: "http://127.0.0.1:\(server.port)")!,
            token: "local-token",
            audioOutput: audio
        )

        player.start()
        await fulfillment(
            of: [segmentRequested, audio.scheduled, audio.initialResume],
            timeout: 1
        )
        XCTAssertEqual(audio.segment, bytes)

        player.setPaused(true)
        await fulfillment(of: [audio.paused], timeout: 1)
        player.setPaused(false)
        await fulfillment(of: [audio.resumed], timeout: 1)
        player.stop()
        await fulfillment(of: [audio.flushed, audio.stopped], timeout: 1)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.path.hasPrefix("/segment?"))
        XCTAssertTrue(request.path.contains("after=0"))
        XCTAssertTrue(request.path.contains("played=0"))
        XCTAssertEqual(
            request.headers["authorization"],
            "Bearer local-token"
        )
    }
}


final class InstalledAppProcessSmokeTests: XCTestCase {
    func testInstalledBundleLifecycleWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let bundle = environment["WREN_INSTALLED_APP_SMOKE"],
              !bundle.isEmpty else {
            throw XCTSkip(
                "Set WREN_INSTALLED_APP_SMOKE to a staged Wren.app."
            )
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repository
            .appendingPathComponent("scripts/smoke-installed.sh")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, bundle]
        process.currentDirectoryURL = repository
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let transcript = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(
            process.terminationStatus,
            0,
            transcript
        )
    }
}


private final class FakeManagedChild: ManagedDaemonChild,
    @unchecked Sendable {
    private let lock = NSLock()
    private let onTerminate: () -> Void
    private var running = true
    private var terminations = 0

    init(onTerminate: @escaping () -> Void = {}) {
        self.onTerminate = onTerminate
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var terminateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminations
    }

    func terminate() {
        lock.lock()
        terminations += 1
        running = false
        lock.unlock()
        onTerminate()
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class FakeSegmentAudioOutput: SegmentAudioOutput,
    @unchecked Sendable {
    let scheduled: XCTestExpectation
    let initialResume: XCTestExpectation
    let paused: XCTestExpectation
    let resumed: XCTestExpectation
    let flushed: XCTestExpectation
    let stopped: XCTestExpectation

    private let lock = NSLock()
    private var storedSegment: Data?
    private var resumeCount = 0

    init(testCase: XCTestCase) {
        scheduled = testCase.expectation(description: "audio scheduled")
        initialResume = testCase.expectation(
            description: "initial playback started"
        )
        paused = testCase.expectation(description: "audio paused")
        resumed = testCase.expectation(description: "audio resumed")
        flushed = testCase.expectation(description: "audio flushed")
        stopped = testCase.expectation(description: "audio stopped")
    }

    var segment: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedSegment
    }

    func schedule(
        _ data: Data,
        completion: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        storedSegment = data
        lock.unlock()
        scheduled.fulfill()
        return true
    }

    func pause() {
        paused.fulfill()
    }

    func resumeIfRunning() {
        lock.lock()
        resumeCount += 1
        let count = resumeCount
        lock.unlock()
        if count == 1 {
            initialResume.fulfill()
        } else if count == 2 {
            resumed.fulfill()
        }
    }

    func setRate(_ rate: Float) {}

    func flush() {
        flushed.fulfill()
    }

    func shutdown() {
        stopped.fulfill()
    }
}

