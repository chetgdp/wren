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
        backend.transports = [10: 0, 20: 0, 30: 0]
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

    func testSnapshotExcludesAggregateAndVirtualDevices() throws {
        let backend = TestAudioHardwareBackend()
        backend.ids = [1, 2, 3, 4]
        backend.channels = [1: 2, 2: 2, 3: 2, 4: 2]
        backend.transports = [
            1: 0,
            2: kAudioDeviceTransportTypeAggregate,
            3: kAudioDeviceTransportTypeVirtual,
            4: kAudioDeviceTransportTypeAutoAggregate,
        ]
        backend.uids = [1: "speaker", 2: "agg", 3: "virt", 4: "auto"]
        backend.names = [1: "Real Speakers", 2: "Agg", 3: "Virt", 4: "Auto"]
        backend.defaultID = 1
        let provider = CoreAudioOutputDeviceProvider(backend: backend)

        let snapshot = try provider.snapshot()

        XCTAssertEqual(snapshot.devices, [
            AudioOutputDevice(uid: "speaker", name: "Real Speakers"),
        ])
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
            44
        )
        XCTAssertNil(try provider.resolve(uid: "missing"))
    }
}

private final class TestAudioHardwareBackend: AudioHardwareBackend {
    var ids: [AudioDeviceID] = []
    var channels: [AudioDeviceID: UInt32] = [:]
    var transports: [AudioDeviceID: UInt32] = [:]
    var uids: [AudioDeviceID: String] = [:]
    var names: [AudioDeviceID: String] = [:]
    var translations: [String: AudioDeviceID] = [:]
    var defaultID = AudioDeviceID(kAudioObjectUnknown)

    func deviceIDs() throws -> [AudioDeviceID] { ids }
    func outputChannelCount(deviceID: AudioDeviceID) throws -> UInt32 {
        channels[deviceID, default: 0]
    }
    func transportType(deviceID: AudioDeviceID) throws -> UInt32 {
        transports[deviceID, default: 0]
    }
    func deviceUID(deviceID: AudioDeviceID) throws -> String {
        uids[deviceID] ?? ""
    }
    func deviceName(deviceID: AudioDeviceID) throws -> String {
        names[deviceID] ?? ""
    }
    func translate(uid: String) throws -> AudioDeviceID? { translations[uid] }
    func defaultOutputDeviceID() throws -> AudioDeviceID {
        guard defaultID != kAudioObjectUnknown else {
            throw AudioOutputError.noDefaultOutput
        }
        return defaultID
    }
    func addListener(
        _ registration: AudioPropertyListenerRegistration
    ) throws {}
    func removeListener(
        _ registration: AudioPropertyListenerRegistration
    ) throws {}
}
