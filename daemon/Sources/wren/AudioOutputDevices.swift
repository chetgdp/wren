import AudioToolbox
import CoreAudio
import Foundation

struct AudioOutputDevice: Equatable, Sendable {
    let uid: String
    let name: String
}

struct ResolvedAudioOutputDevice: Equatable, Sendable {
    let device: AudioOutputDevice
    let objectID: AudioDeviceID
}

struct AudioOutputDeviceSnapshot: Equatable, Sendable {
    let devices: [AudioOutputDevice]
    let defaultDevice: ResolvedAudioOutputDevice
}

enum AudioOutputDeviceChange: Sendable {
    case devices
    case defaultOutput
}

enum AudioOutputError: Error, Equatable, Sendable, CustomStringConvertible {
    case osStatus(operation: String, status: OSStatus)
    case invalidProperty(operation: String)
    case deviceDisconnected(uid: String)
    case noDefaultOutput
    case missingAudioUnit
    case readbackMismatch(requested: AudioDeviceID, actual: AudioDeviceID)
    case engineRestart(String)

    var description: String {
        switch self {
        case .osStatus(let operation, let status):
            return "\(operation) failed (\(status))."
        case .invalidProperty(let operation):
            return "\(operation) returned invalid property data."
        case .deviceDisconnected(let uid):
            return "Output device \(uid) is disconnected."
        case .noDefaultOutput:
            return "No system default output device is available."
        case .missingAudioUnit:
            return "The audio engine has no output AudioUnit."
        case .readbackMismatch(let req, let act):
            return "Output device readback mismatch: req \(req), act \(act)."
        case .engineRestart(let detail):
            return "The audio engine could not restart: \(detail)"
        }
    }
}

protocol AudioOutputDeviceProviding: AnyObject {
    func snapshot() throws -> AudioOutputDeviceSnapshot
    func resolve(uid: String) throws -> ResolvedAudioOutputDevice?
    func startObserving(
        _ handler: @escaping @Sendable (AudioOutputDeviceChange) -> Void
    ) throws
    func stopObserving()
}

final class AudioPropertyListenerRegistration {
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    init(
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.address = address
        self.queue = queue
        self.block = block
    }
}

protocol AudioHardwareBackend: AnyObject {
    func deviceIDs() throws -> [AudioDeviceID]
    func outputChannelCount(deviceID: AudioDeviceID) throws -> UInt32
    func transportType(deviceID: AudioDeviceID) throws -> UInt32
    func isHidden(deviceID: AudioDeviceID) throws -> Bool
    func canBeDefaultOutput(deviceID: AudioDeviceID) throws -> Bool
    func deviceUID(deviceID: AudioDeviceID) throws -> String
    func deviceName(deviceID: AudioDeviceID) throws -> String
    func translate(uid: String) throws -> AudioDeviceID?
    func defaultOutputDeviceID() throws -> AudioDeviceID
    func addListener(_ registration: AudioPropertyListenerRegistration) throws
    func removeListener(
        _ registration: AudioPropertyListenerRegistration
    ) throws
}

final class CoreAudioOutputDeviceProvider: AudioOutputDeviceProviding {
    private let backend: AudioHardwareBackend
    private let listenerQueue: DispatchQueue
    private let lock = NSLock()
    private var listeners: [AudioPropertyListenerRegistration] = []

    init(
        backend: AudioHardwareBackend = CoreAudioHardwareBackend(),
        listenerQueue: DispatchQueue = DispatchQueue(
            label: "wren.audio-output-devices"
        )
    ) {
        self.backend = backend
        self.listenerQueue = listenerQueue
    }

    deinit {
        stopObserving()
    }

    func snapshot() throws -> AudioOutputDeviceSnapshot {
        // A device that vanishes or misreports mid-enumeration (unplugged
        // USB DAC) is skipped rather than emptying the whole list.
        let resolved = try backend.deviceIDs().compactMap { deviceID in
            (try? resolve(deviceID: deviceID)) ?? nil
        }
        let devices = resolved
            .map(\.device)
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        let defaultID = try backend.defaultOutputDeviceID()
        guard defaultID != kAudioObjectUnknown,
              let defaultDevice = try resolve(
                deviceID: defaultID,
                allowNonStandard: true
              ) else {
            throw AudioOutputError.noDefaultOutput
        }
        return AudioOutputDeviceSnapshot(
            devices: devices,
            defaultDevice: defaultDevice
        )
    }

    func resolve(uid: String) throws -> ResolvedAudioOutputDevice? {
        guard let deviceID = try backend.translate(uid: uid) else {
            return nil
        }
        return try resolve(deviceID: deviceID, allowNonStandard: true)
    }

    func startObserving(
        _ handler: @escaping @Sendable (AudioOutputDeviceChange) -> Void
    ) throws {
        stopObserving()
        let descriptors = [
            (
                address: Self.address(
                    selector: kAudioHardwarePropertyDevices
                ),
                change: AudioOutputDeviceChange.devices
            ),
            (
                address: Self.address(
                    selector: kAudioHardwarePropertyDefaultOutputDevice
                ),
                change: AudioOutputDeviceChange.defaultOutput
            ),
        ]
        var added: [AudioPropertyListenerRegistration] = []
        for descriptor in descriptors {
            let expected = descriptor.address.mSelector
            let change = descriptor.change
            let block: AudioObjectPropertyListenerBlock = {
                count, addresses in
                for index in 0 ..< Int(count)
                where addresses[index].mSelector == expected {
                    handler(change)
                    return
                }
            }
            let reg = AudioPropertyListenerRegistration(
                address: descriptor.address,
                queue: listenerQueue,
                block: block
            )
            try backend.addListener(reg)
            added.append(reg)
        }
        lock.lock()
        listeners = added
        lock.unlock()
    }

    func stopObserving() {
        lock.lock()
        let current = listeners
        listeners = []
        lock.unlock()
        for listener in current.reversed() {
            try? backend.removeListener(listener)
        }
    }

    private func resolve(
        deviceID: AudioDeviceID,
        allowNonStandard: Bool = false
    ) throws -> ResolvedAudioOutputDevice? {
        // Input-only devices (microphones) report zero output channels.
        guard try backend.outputChannelCount(deviceID: deviceID) > 0 else {
            return nil
        }
        // Aggregates and virtual drivers (Zoom, BlackHole, Teams) are not
        // speakers a user picks; the system default still resolves even
        // when it is one of them, so playback never loses its route.
        if !allowNonStandard {
            if try backend.isHidden(deviceID: deviceID) {
                return nil
            }
            if try !backend.canBeDefaultOutput(deviceID: deviceID) {
                return nil
            }
            let transport = try backend.transportType(deviceID: deviceID)
            let excludedTransports: Set<UInt32> = [
                kAudioDeviceTransportTypeAggregate,
                kAudioDeviceTransportTypeAutoAggregate,
                kAudioDeviceTransportTypeVirtual,
            ]
            if excludedTransports.contains(transport) {
                return nil
            }
        }

        return ResolvedAudioOutputDevice(
            device: AudioOutputDevice(
                uid: try backend.deviceUID(deviceID: deviceID),
                name: try backend.deviceName(deviceID: deviceID)
            ),
            objectID: deviceID
        )
    }

    private static func address(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

final class CoreAudioHardwareBackend: AudioHardwareBackend {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func deviceIDs() throws -> [AudioDeviceID] {
        let address = propertyAddress(
            selector: kAudioHardwarePropertyDevices
        )
        let size = try propertySize(
            objectID: systemObject,
            address: address,
            operation: "Enumerating audio devices"
        )
        let stride = UInt32(MemoryLayout<AudioDeviceID>.stride)
        guard size > 0, size % stride == 0 else {
            throw AudioOutputError.invalidProperty(
                operation: "Enumerating audio devices"
            )
        }
        var ids = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size / stride)
        )
        var returnedSize = size
        var mutableAddress = address
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                systemObject,
                &mutableAddress,
                0,
                nil,
                &returnedSize,
                bytes.baseAddress!
            )
        }
        try requireSuccess(status, operation: "Enumerating audio devices")
        return ids
    }

    func outputChannelCount(deviceID: AudioDeviceID) throws -> UInt32 {
        let address = propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeOutput
        )
        let size = try propertySize(
            objectID: deviceID,
            address: address,
            operation: "Reading output channels"
        )
        guard size >= UInt32(MemoryLayout<UInt32>.size) else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        var returnedSize = size
        var mutableAddress = address
        let status = AudioObjectGetPropertyData(
            deviceID,
            &mutableAddress,
            0,
            nil,
            &returnedSize,
            raw
        )
        try requireSuccess(status, operation: "Reading output channels")
        return try Self.outputChannelCount(
            from: UnsafeRawBufferPointer(start: raw, count: Int(size))
        )
    }

    static func outputChannelCount(
        from raw: UnsafeRawBufferPointer
    ) throws -> UInt32 {
        guard raw.count >= MemoryLayout<UInt32>.size,
              let bufferOffset = MemoryLayout<AudioBufferList>.offset(
                of: \AudioBufferList.mBuffers
              ),
              let channelOffset = MemoryLayout<AudioBuffer>.offset(
                of: \AudioBuffer.mNumberChannels
              )
        else {
            return 0
        }
        let bufferCount = UInt64(raw.load(as: UInt32.self))
        guard bufferCount > 0 else { return 0 }
        let bufferStride = MemoryLayout<AudioBuffer>.stride
        guard bufferStride >= MemoryLayout<UInt32>.size,
              channelOffset <= bufferStride - MemoryLayout<UInt32>.size,
              bufferOffset <= raw.count,
              bufferCount <= UInt64(
                (raw.count - bufferOffset) / bufferStride
              )
        else {
            return 0
        }
        var channelCount: UInt32 = 0
        for index in 0 ..< Int(bufferCount) {
            let offset = bufferOffset + index * bufferStride + channelOffset
            let channels = raw.load(
                fromByteOffset: offset,
                as: UInt32.self
            )
            let (updated, overflow) =
                channelCount.addingReportingOverflow(channels)
            guard !overflow else { return channelCount }
            channelCount = updated
        }
        return channelCount
    }

    func transportType(deviceID: AudioDeviceID) throws -> UInt32 {
        var address = propertyAddress(
            selector: kAudioDevicePropertyTransportType
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transport
        )
        if status != noErr {
            return 0
        }
        return transport
    }
    func isHidden(deviceID: AudioDeviceID) throws -> Bool {
        var address = propertyAddress(
            selector: kAudioDevicePropertyIsHidden
        )
        var isHidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &isHidden
        )
        if status != noErr {
            return false
        }
        return isHidden != 0
    }

    func canBeDefaultOutput(deviceID: AudioDeviceID) throws -> Bool {
        var address = propertyAddress(
            selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            scope: kAudioObjectPropertyScopeOutput
        )
        var canBeDefault: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &canBeDefault
        )
        if status != noErr {
            return true
        }
        return canBeDefault != 0
    }


    func deviceUID(deviceID: AudioDeviceID) throws -> String {
        try stringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            operation: "Reading audio device UID"
        )
    }

    func deviceName(deviceID: AudioDeviceID) throws -> String {
        try stringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyName,
            operation: "Reading audio device name"
        )
    }

    func translate(uid: String) throws -> AudioDeviceID? {
        var address = propertyAddress(
            selector: kAudioHardwarePropertyTranslateUIDToDevice
        )
        let qualifierValue = uid as CFString
        var qualifier = Unmanaged.passUnretained(qualifierValue)
        var result = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                UInt32(MemoryLayout<Unmanaged<CFString>>.stride),
                pointer,
                &size,
                &result
            )
        }
        try requireSuccess(status, operation: "Resolving audio device UID")
        return result == kAudioObjectUnknown ? nil : result
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = propertyAddress(
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        var result = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &result
        )
        try requireSuccess(status, operation: "Reading default output")
        return result
    }

    func addListener(
        _ registration: AudioPropertyListenerRegistration
    ) throws {
        var address = registration.address
        let status = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &address,
            registration.queue,
            registration.block
        )
        try requireSuccess(status, operation: "Adding audio device listener")
    }

    func removeListener(
        _ registration: AudioPropertyListenerRegistration
    ) throws {
        var address = registration.address
        let status = AudioObjectRemovePropertyListenerBlock(
            systemObject,
            &address,
            registration.queue,
            registration.block
        )
        try requireSuccess(status, operation: "Removing audio device listener")
    }

    private func stringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        var address = propertyAddress(selector: selector)
        var value: Unmanaged<CFString>?
        let expectedSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var size = expectedSize
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        try requireSuccess(status, operation: operation)
        guard size == expectedSize, let value else {
            throw AudioOutputError.invalidProperty(operation: operation)
        }
        return value.takeRetainedValue() as String
    }

    private func propertySize(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            objectID,
            &address,
            0,
            nil,
            &size
        )
        try requireSuccess(status, operation: operation)
        return size
    }

    private func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func requireSuccess(
        _ status: OSStatus,
        operation: String
    ) throws {
        guard status == noErr else {
            throw AudioOutputError.osStatus(
                operation: operation,
                status: status
            )
        }
    }
}
