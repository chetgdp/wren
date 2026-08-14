import AudioToolbox
import CoreAudio
import Foundation
import XCTest
@testable import wren

final class AudioOutputDeviceProviderTests: XCTestCase {
    func testSnapshotFiltersOutputsAndKeepsStableUIDs() throws {
        let backend = TestAudioHardwareBackend()
        backend.ids = [10, 20, 30]
        backend.channels = [10: 2, 20: 0, 30: 2]
        backend.uids = [10: "uid-z", 20: "input", 30: "uid-a"]
        backend.names = [10: "Zulu", 20: "Input", 30: "Alpha"]
        backend.defaultID = 10
        let provider = CoreAudioOutputDeviceProvider(backend: backend)

        let snapshot = try provider.snapshot()

        XCTAssertEqual(snapshot.devices, [
            AudioOutputDevice(uid: "uid-a", name: "Alpha"),
            AudioOutputDevice(uid: "uid-z", name: "Zulu"),
        ])
        XCTAssertEqual(snapshot.defaultDevice.objectID, 10)
        XCTAssertEqual(snapshot.defaultDevice.device.uid, "uid-z")
    }

    func testEnumerationErrorIsNotCollapsedToEmptyList() {
        let backend = TestAudioHardwareBackend()
        backend.deviceIDsError = AudioOutputError.osStatus(
            operation: "Enumerating audio devices",
            status: -50)
        let provider = CoreAudioOutputDeviceProvider(backend: backend)

        XCTAssertThrowsError(try provider.snapshot()) { error in
            XCTAssertEqual(
                error as? AudioOutputError,
                backend.deviceIDsError as? AudioOutputError)
        }
    }

    func testUIDTranslationTreatsUnknownAsDisconnected() throws {
        let backend = TestAudioHardwareBackend()
        backend.translations["connected"] = 44
        backend.channels[44] = 2
        backend.uids[44] = "connected"
        backend.names[44] = "Desk DAC"
        let provider = CoreAudioOutputDeviceProvider(backend: backend)

        XCTAssertEqual(
            try provider.resolve(uid: "connected")?.objectID,
            44)
        XCTAssertNil(try provider.resolve(uid: "missing"))
    }

    func testListenersUseSameQueueAndBlockWhenRemoved() throws {
        let backend = TestAudioHardwareBackend()
        let queue = DispatchQueue(label: "test.output-listeners")
        let provider = CoreAudioOutputDeviceProvider(
            backend: backend,
            listenerQueue: queue)
        let defaultChanged = expectation(description: "default changed")
        let devicesChanged = expectation(description: "devices changed")
        let postTeardown = expectation(
            description: "no callback after teardown")
        postTeardown.isInverted = true
        let probe = ListenerCallbackProbe(
            first: devicesChanged,
            later: postTeardown)
        try provider.startObserving { change in
            switch change {
            case .devices:
                probe.receive()
            case .defaultOutput:
                defaultChanged.fulfill()
            }
        }
        XCTAssertEqual(backend.added.count, 2)

        backend.emit(selector: kAudioHardwarePropertyDevices)
        backend.emit(selector: kAudioHardwarePropertyDefaultOutputDevice)
        wait(for: [devicesChanged, defaultChanged], timeout: 1)
        provider.stopObserving()
        backend.emit(selector: kAudioHardwarePropertyDevices)
        wait(for: [postTeardown], timeout: 0.05)

        XCTAssertEqual(backend.removed.count, 2)
        XCTAssertTrue(backend.removalsMatchedRegistration)
    }

    func testPartialListenerFailureRollsBackFirstListener() {
        let backend = TestAudioHardwareBackend()
        backend.listenerAddFailureIndex = 1
        let provider = CoreAudioOutputDeviceProvider(backend: backend)

        XCTAssertThrowsError(try provider.startObserving { _ in })
        XCTAssertEqual(backend.added.count, 1)
        XCTAssertEqual(backend.removed.count, 1)
        XCTAssertTrue(backend.removalsMatchedRegistration)
    }

    func testOutputChannelParserAcceptsZeroBufferConfiguration() throws {
        let bytes = [UInt8](
            repeating: 0,
            count: MemoryLayout<UInt32>.size)

        XCTAssertEqual(
            try bytes.withUnsafeBytes { raw in
                try CoreAudioHardwareBackend.outputChannelCount(from: raw)
            },
            0)
    }

    func testOutputChannelParserRejectsMissingCountField() {
        let bytes = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size - 1)

        XCTAssertThrowsError(
            try bytes.withUnsafeBytes { raw in
                try CoreAudioHardwareBackend.outputChannelCount(from: raw)
            }) { error in
                XCTAssertEqual(
                    error as? AudioOutputError,
                    .invalidProperty(operation: "Reading output channels"))
            }
    }

    func testOutputChannelParserSumsVariableLengthBufferList() throws {
        let bufferOffset = MemoryLayout<AudioBufferList>.offset(
            of: \AudioBufferList.mBuffers)!
        let channelOffset = MemoryLayout<AudioBuffer>.offset(
            of: \AudioBuffer.mNumberChannels)!
        let bufferStride = MemoryLayout<AudioBuffer>.stride
        var bytes = [UInt8](
            repeating: 0,
            count: bufferOffset + 2 * bufferStride)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(2), as: UInt32.self)
            raw.storeBytes(
                of: UInt32(2),
                toByteOffset: bufferOffset + channelOffset,
                as: UInt32.self)
            raw.storeBytes(
                of: UInt32(1),
                toByteOffset: bufferOffset + bufferStride + channelOffset,
                as: UInt32.self)
        }

        XCTAssertEqual(
            try bytes.withUnsafeBytes { raw in
                try CoreAudioHardwareBackend.outputChannelCount(from: raw)
            },
            3)
    }

    func testOutputChannelParserRejectsTruncatedBufferArray() {
        let bufferOffset = MemoryLayout<AudioBufferList>.offset(
            of: \AudioBufferList.mBuffers)!
        let bytesCount = bufferOffset + MemoryLayout<AudioBuffer>.stride
        var bytes = [UInt8](repeating: 0, count: bytesCount)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(2), as: UInt32.self)
        }

        XCTAssertThrowsError(
            try bytes.withUnsafeBytes { raw in
                try CoreAudioHardwareBackend.outputChannelCount(from: raw)
            }) { error in
                XCTAssertEqual(
                    error as? AudioOutputError,
                    .invalidProperty(operation: "Reading output channels"))
            }
    }

}

private final class TestAudioHardwareBackend: AudioHardwareBackend {

    var ids: [AudioDeviceID] = []
    var channels: [AudioDeviceID: UInt32] = [:]
    var uids: [AudioDeviceID: String] = [:]
    var names: [AudioDeviceID: String] = [:]
    var translations: [String: AudioDeviceID] = [:]
    var defaultID = AudioDeviceID(kAudioObjectUnknown)
    var deviceIDsError: Error?
    var listenerAddFailureIndex: Int?
    private var removedSelectors: Set<AudioObjectPropertySelector> = []
    private(set) var added: [AudioPropertyListenerRegistration] = []
    private(set) var removed: [AudioPropertyListenerRegistration] = []
    private(set) var removalsMatchedRegistration = true

    func deviceIDs() throws -> [AudioDeviceID] {
        if let deviceIDsError { throw deviceIDsError }
        return ids
    }

    func outputChannelCount(
        deviceID: AudioDeviceID
    ) throws -> UInt32 {
        channels[deviceID, default: 0]
    }

    func deviceUID(deviceID: AudioDeviceID) throws -> String {
        try value(uids[deviceID])
    }

    func deviceName(deviceID: AudioDeviceID) throws -> String {
        try value(names[deviceID])
    }

    func translate(uid: String) throws -> AudioDeviceID? {
        translations[uid]
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID {
        guard defaultID != kAudioObjectUnknown else {
            throw AudioOutputError.noDefaultOutput
        }
        return defaultID
    }

    func addListener(
        _ registration: AudioPropertyListenerRegistration
    ) throws {
        if listenerAddFailureIndex == added.count {
            throw AudioOutputError.osStatus(
                operation: "Adding audio device listener",
                status: -50)
        }
        added.append(registration)
    }

    func removeListener(
        _ registration: AudioPropertyListenerRegistration
    ) throws {
        removed.append(registration)
        removedSelectors.insert(registration.address.mSelector)
        let match = added.contains { $0 === registration }
        removalsMatchedRegistration = removalsMatchedRegistration && match
    }

    func emit(selector: AudioObjectPropertySelector) {
        guard !removedSelectors.contains(selector),
              let listener = added.first(where: {
                  $0.address.mSelector == selector
              }) else { return }
        listener.queue.async {
            var address = listener.address
            withUnsafePointer(to: &address) { pointer in
                listener.block(1, pointer)
            }
        }
    }

    private func value<T>(_ value: T?) throws -> T {
        guard let value else {
            throw AudioOutputError.invalidProperty(operation: "test")
        }
        return value
    }
}

private final class ListenerCallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let first: XCTestExpectation
    private let later: XCTestExpectation
    private var hasReceived = false

    init(first: XCTestExpectation, later: XCTestExpectation) {
        self.first = first
        self.later = later
    }

    func receive() {
        lock.lock()
        let isFirst = !hasReceived
        hasReceived = true
        lock.unlock()
        if isFirst {
            first.fulfill()
        } else {
            later.fulfill()
        }
    }
}
