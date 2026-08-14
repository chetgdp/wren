import CoreAudio
import XCTest
@testable import wren

final class AudioOutputPlayerTests: XCTestCase {
    func testSelectionStopsSetsReadsBackAndRestarts() throws {
        let route = TestEngineOutputRoute()
        route.readbackID = 42
        let applier = AVAudioEngineOutputDeviceApplier()

        try applier.apply(
            deviceID: 42,
            route: route,
            shouldRun: true)

        XCTAssertEqual(route.events, [
            "stop",
            "set:42",
            "read",
            "prepare",
            "start",
        ])
        XCTAssertTrue(route.isRunning)
    }

    func testReadbackMismatchRestartsBeforeReportingFailure() {
        let route = TestEngineOutputRoute()
        route.readbackID = 7
        let applier = AVAudioEngineOutputDeviceApplier()

        XCTAssertThrowsError(try applier.apply(
            deviceID: 42,
            route: route,
            shouldRun: true)) { error in
            XCTAssertEqual(
                error as? AudioOutputError,
                .readbackMismatch(requested: 42, actual: 7))
        }
        XCTAssertEqual(route.events, [
            "stop",
            "set:42",
            "read",
            "prepare",
            "start",
        ])
        XCTAssertTrue(route.isRunning)
    }

    func testSetterFailureDoesNotLeaveRunningEngineStopped() {
        let route = TestEngineOutputRoute()
        route.setError = AudioOutputError.osStatus(
            operation: "Selecting output device",
            status: -10849)
        let applier = AVAudioEngineOutputDeviceApplier()

        XCTAssertThrowsError(try applier.apply(
            deviceID: 42,
            route: route,
            shouldRun: true))
        XCTAssertEqual(route.events, [
            "stop",
            "set:42",
            "prepare",
            "start",
        ])
        XCTAssertTrue(route.isRunning)
    }

    func testStoppedEngineRemainsStoppedAfterSelection() throws {
        let route = TestEngineOutputRoute()
        route.readbackID = 42
        let applier = AVAudioEngineOutputDeviceApplier()

        try applier.apply(
            deviceID: 42,
            route: route,
            shouldRun: false)

        XCTAssertEqual(route.events, ["stop", "set:42", "read"])
        XCTAssertFalse(route.isRunning)
    }
}

private final class TestEngineOutputRoute: AudioEngineOutputRouting {
    var isRunning = true
    var readbackID = AudioDeviceID(kAudioObjectUnknown)
    var setError: Error?
    var startError: Error?
    private(set) var events: [String] = []

    func stop() {
        events.append("stop")
        isRunning = false
    }

    func prepare() {
        events.append("prepare")
    }

    func start() throws {
        events.append("start")
        if let startError { throw startError }
        isRunning = true
    }

    func setCurrentDevice(_ deviceID: AudioDeviceID) throws {
        events.append("set:\(deviceID)")
        if let setError { throw setError }
    }

    func currentDevice() throws -> AudioDeviceID {
        events.append("read")
        return readbackID
    }
}
