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

enum AudioOutputError: Error, Equatable, Sendable,
    CustomStringConvertible {
    case osStatus(operation: String, status: OSStatus)
    case invalidProperty(operation: String)
    case deviceDisconnected(uid: String)
    case noDefaultOutput
    case missingAudioUnit
    case readbackMismatch(
        requested: AudioDeviceID,
        actual: AudioDeviceID
    )
    case engineRestart(String)

    var description: String {
        switch self {
        case .osStatus(let operation, let status):
            return "\(operation) failed (\(Self.describe(status)))."
        case .invalidProperty(let operation):
            return "\(operation) returned invalid property data."
        case .deviceDisconnected(let uid):
            return "Output device \(uid) is disconnected."
        case .noDefaultOutput:
            return "No system default output device is available."
        case .missingAudioUnit:
            return "The audio engine has no output AudioUnit."
        case .readbackMismatch(let requested, let actual):
            return "Output device readback was \(actual), expected "
                + "\(requested)."
        case .engineRestart(let detail):
            return "The audio engine could not restart: \(detail)"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 <= 126 }
        guard printable, let fourCC = String(bytes: bytes,
                                             encoding: .ascii) else {
            return String(status)
        }
        return "\(status), '\(fourCC)'"
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
    func outputChannelCount(
        deviceID: AudioDeviceID
    ) throws -> UInt32
    func deviceUID(deviceID: AudioDeviceID) throws -> String
    func deviceName(deviceID: AudioDeviceID) throws -> String
    func translate(uid: String) throws -> AudioDeviceID?
    func defaultOutputDeviceID() throws -> AudioDeviceID
    func addListener(
        _ registration: AudioPropertyListenerRegistration
    ) throws
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
            label: "wren.audio-output-devices")
    ) {
        self.backend = backend
        self.listenerQueue = listenerQueue
    }

    deinit {
        stopObserving()
    }

    func snapshot() throws -> AudioOutputDeviceSnapshot {
        let resolved = try backend.deviceIDs().compactMap { deviceID in
            try resolve(deviceID: deviceID)
        }
        let devices = resolved
            .map(\.device)
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        let defaultID = try backend.defaultOutputDeviceID()
        guard defaultID != kAudioObjectUnknown,
              let defaultDevice = try resolve(deviceID: defaultID) else {
            throw AudioOutputError.noDefaultOutput
        }
        return AudioOutputDeviceSnapshot(
            devices: devices,
            defaultDevice: defaultDevice)
    }

    func resolve(uid: String) throws -> ResolvedAudioOutputDevice? {
        guard let deviceID = try backend.translate(uid: uid) else {
            return nil
        }
        return try resolve(deviceID: deviceID)
    }

    func startObserving(
        _ handler: @escaping @Sendable (AudioOutputDeviceChange) -> Void
    ) throws {
        stopObserving()
        let descriptors = [
            (
                address: Self.address(
                    selector: kAudioHardwarePropertyDevices),
                change: AudioOutputDeviceChange.devices
            ),
            (
                address: Self.address(
                    selector: kAudioHardwarePropertyDefaultOutputDevice),
                change: AudioOutputDeviceChange.defaultOutput
            ),
        ]
        var added: [AudioPropertyListenerRegistration] = []
        do {
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
                let registration = AudioPropertyListenerRegistration(
                    address: descriptor.address,
                    queue: listenerQueue,
                    block: block)
                try backend.addListener(registration)
                added.append(registration)
            }
        } catch {
            for listener in added.reversed() {
                do {
                    try backend.removeListener(listener)
                } catch {
                    NSLog(
                        "wren output listener rollback failed: \(error)")
                }
            }
            throw error
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
            do {
                try backend.removeListener(listener)
            } catch {
                NSLog("wren output listener removal failed: \(error)")
            }
        }
    }

    private func resolve(
        deviceID: AudioDeviceID
    ) throws -> ResolvedAudioOutputDevice? {
        guard try backend.outputChannelCount(deviceID: deviceID) > 0 else {
            return nil
        }
        return ResolvedAudioOutputDevice(
            device: AudioOutputDevice(
                uid: try backend.deviceUID(deviceID: deviceID),
                name: try backend.deviceName(deviceID: deviceID)),
            objectID: deviceID)
    }

    private static func address(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

}

final class CoreAudioHardwareBackend: AudioHardwareBackend {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func deviceIDs() throws -> [AudioDeviceID] {
        do {
            return try readDeviceIDs()
        } catch {
            return try readDeviceIDs()
        }
    }

    private func readDeviceIDs() throws -> [AudioDeviceID] {
        let address = propertyAddress(
            selector: kAudioHardwarePropertyDevices)
        let size = try propertySize(
            objectID: systemObject,
            address: address,
            operation: "Enumerating audio devices")
        let stride = UInt32(MemoryLayout<AudioDeviceID>.stride)
        guard size > 0, size % stride == 0 else {
            throw AudioOutputError.invalidProperty(
                operation: "Enumerating audio devices")
        }
        var ids = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size / stride))
        var returnedSize = size
        let status = ids.withUnsafeMutableBytes { bytes in
            var address = address
            return AudioObjectGetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                &returnedSize,
                bytes.baseAddress!)
        }
        try requireSuccess(status, operation: "Enumerating audio devices")
        guard returnedSize == size else {
            throw AudioOutputError.invalidProperty(
                operation: "Enumerating audio devices")
        }
        return ids
    }

    func outputChannelCount(
        deviceID: AudioDeviceID
    ) throws -> UInt32 {
        let address = propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeOutput)
        let size = try propertySize(
            objectID: deviceID,
            address: address,
            operation: "Reading output channels")
        guard size >= UInt32(MemoryLayout<UInt32>.size) else {
            throw AudioOutputError.invalidProperty(
                operation: "Reading output channels")
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var returnedSize = size
        var mutableAddress = address
        let status = AudioObjectGetPropertyData(
            deviceID,
            &mutableAddress,
            0,
            nil,
            &returnedSize,
            raw)
        try requireSuccess(status, operation: "Reading output channels")
        guard returnedSize == size else {
            throw AudioOutputError.invalidProperty(
                operation: "Reading output channels")
        }
        return try Self.outputChannelCount(
            from: UnsafeRawBufferPointer(start: raw, count: Int(size)))
    }

    static func outputChannelCount(
        from raw: UnsafeRawBufferPointer
    ) throws -> UInt32 {
        let operation = "Reading output channels"
        guard raw.count >= MemoryLayout<UInt32>.size,
              let bufferOffset = MemoryLayout<AudioBufferList>.offset(
                of: \AudioBufferList.mBuffers),
              let channelOffset = MemoryLayout<AudioBuffer>.offset(
                of: \AudioBuffer.mNumberChannels)
        else {
            throw AudioOutputError.invalidProperty(operation: operation)
        }
        let bufferCount = UInt64(raw.load(as: UInt32.self))
        guard bufferCount > 0 else {
            return 0
        }
        let bufferStride = MemoryLayout<AudioBuffer>.stride
        guard bufferStride >= MemoryLayout<UInt32>.size,
              channelOffset <= bufferStride - MemoryLayout<UInt32>.size,
              bufferOffset <= raw.count,
              bufferCount <= UInt64(
                (raw.count - bufferOffset) / bufferStride)
        else {
            throw AudioOutputError.invalidProperty(operation: operation)
        }
        var channelCount: UInt32 = 0
        for index in 0 ..< Int(bufferCount) {
            let offset = bufferOffset + index * bufferStride + channelOffset
            let channels = raw.load(
                fromByteOffset: offset,
                as: UInt32.self)
            let (updatedCount, overflow) =
                channelCount.addingReportingOverflow(channels)
            guard !overflow else {
                throw AudioOutputError.invalidProperty(operation: operation)
            }
            channelCount = updatedCount
        }
        return channelCount
    }

    func deviceUID(deviceID: AudioDeviceID) throws -> String {
        try stringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            operation: "Reading audio device UID")
    }

    func deviceName(deviceID: AudioDeviceID) throws -> String {
        try stringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyName,
            operation: "Reading audio device name")
    }

    func translate(uid: String) throws -> AudioDeviceID? {
        var address = propertyAddress(
            selector: kAudioHardwarePropertyTranslateUIDToDevice)
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
                &result)
        }
        try requireSuccess(status, operation: "Resolving audio device UID")
        guard size == UInt32(MemoryLayout<AudioDeviceID>.size) else {
            throw AudioOutputError.invalidProperty(
                operation: "Resolving audio device UID")
        }
        return result == kAudioObjectUnknown ? nil : result
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = propertyAddress(
            selector: kAudioHardwarePropertyDefaultOutputDevice)
        var result = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &result)
        try requireSuccess(status, operation: "Reading default output")
        guard size == UInt32(MemoryLayout<AudioDeviceID>.size) else {
            throw AudioOutputError.invalidProperty(
                operation: "Reading default output")
        }
        guard result != kAudioObjectUnknown else {
            throw AudioOutputError.noDefaultOutput
        }
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
            registration.block)
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
            registration.block)
        try requireSuccess(
            status,
            operation: "Removing audio device listener")
    }

    private func stringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        var address = propertyAddress(selector: selector)
        var value: Unmanaged<CFString>?
        let expectedSize =
            UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var size = expectedSize
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                pointer)
        }
        try requireSuccess(status, operation: operation)
        guard size == expectedSize, let value else {
            throw AudioOutputError.invalidProperty(operation: operation)
        }
        let string = value.takeRetainedValue() as String
        guard !string.isEmpty else {
            throw AudioOutputError.invalidProperty(operation: operation)
        }
        return string
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
            &size)
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
            mElement: kAudioObjectPropertyElementMain)
    }

    private func requireSuccess(
        _ status: OSStatus,
        operation: String
    ) throws {
        guard status == noErr else {
            throw AudioOutputError.osStatus(
                operation: operation,
                status: status)
        }
    }
}
