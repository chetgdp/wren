import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum LocalSpeakingRate {
    static let minimum = 0.5
    static let maximum = 3.0

    static func clamped(_ rate: Double) -> Double {
        min(maximum, max(minimum, rate))
    }
}

protocol SegmentAudioOutput: AnyObject, Sendable {
    func schedule(
        _ data: Data,
        completion: @escaping @Sendable () -> Void
    ) -> Bool
    func pause()
    func resumeIfRunning()
    func setRate(_ rate: Float)
    func flush()
    func shutdown()
}

protocol SegmentOutputDeviceApplying: AnyObject, Sendable {
    func apply(
        deviceID: AudioDeviceID,
        to engine: AVAudioEngine,
        shouldRun: Bool
    ) throws
}

protocol AudioEngineOutputRouting: AnyObject {
    var isRunning: Bool { get }
    func stop()
    func prepare()
    func start() throws
    func setCurrentDevice(_ deviceID: AudioDeviceID) throws
    func currentDevice() throws -> AudioDeviceID
}

final class AVAudioEngineOutputDeviceApplier:
    SegmentOutputDeviceApplying,
    @unchecked Sendable {
    func apply(
        deviceID: AudioDeviceID,
        to engine: AVAudioEngine,
        shouldRun: Bool
    ) throws {
        try apply(
            deviceID: deviceID,
            route: AVAudioEngineOutputRoute(engine: engine),
            shouldRun: shouldRun)
    }

    func apply(
        deviceID: AudioDeviceID,
        route: AudioEngineOutputRouting,
        shouldRun: Bool
    ) throws {
        route.stop()
        do {
            try route.setCurrentDevice(deviceID)
            let actual = try route.currentDevice()
            guard actual == deviceID else {
                throw AudioOutputError.readbackMismatch(
                    requested: deviceID,
                    actual: actual)
            }
            if shouldRun {
                route.prepare()
                do {
                    try route.start()
                } catch {
                    throw AudioOutputError.engineRestart(
                        String(describing: error))
                }
            }
        } catch {
            if shouldRun, !route.isRunning {
                route.prepare()
                try? route.start()
            }
            throw error
        }
    }
}

private final class AVAudioEngineOutputRoute:
    AudioEngineOutputRouting {
    private let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    var isRunning: Bool {
        engine.isRunning
    }

    func stop() {
        engine.stop()
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func setCurrentDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw AudioOutputError.missingAudioUnit
        }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw AudioOutputError.osStatus(
                operation: "Selecting output device",
                status: status)
        }
    }

    func currentDevice() throws -> AudioDeviceID {
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw AudioOutputError.missingAudioUnit
        }
        var actual = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &actual,
            &size)
        guard status == noErr else {
            throw AudioOutputError.osStatus(
                operation: "Reading selected output device",
                status: status)
        }
        guard size == UInt32(MemoryLayout<AudioDeviceID>.size) else {
            throw AudioOutputError.invalidProperty(
                operation: "Reading selected output device")
        }
        return actual
    }
}

/// Native player for the daemon's local channel: long-polls GET /segment,
/// decodes each wav, and schedules it gaplessly on one AVAudioEngine graph
/// (player -> AVAudioUnitTimePitch -> output). The Swift port of the
/// extension's offscreen player, with AVAudioUnitTimePitch doing live
/// pitch-preserving rate instead of offline soundtouch stretching.
///
/// The rate here multiplies the daemon's per-request synthesis rate. It is
/// local player state and never changes daemon product settings.
///
/// All state lives on one serial queue; AVFoundation callbacks and URL
/// session completions hop onto it, so there is no shared-state locking.
final class SegmentPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wren.segment-player")
    private let session: URLSession
    private let base: URL
    private let token: String?
    private let audioOutput: SegmentAudioOutput?
    private let outputDeviceApplier: SegmentOutputDeviceApplying

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var connectedFormat: AVAudioFormat?

    private var poll = SegmentPoll()
    private var running = false
    private var userPaused = false
    /// Bumped on every flush; segment-completion callbacks captured before
    /// the flush must not move the played cursor or free anything after it.
    private var localEpoch = 0
    /// The in-flight long poll and the played cursor it reported; when a
    /// segment finishes locally the stale poll is cancelled so the fresh
    /// cursor reaches the daemon now, not a poll cycle later (machine-queue
    /// turn handoff waits on it).
    private var currentTask: URLSessionDataTask?
    private var currentTaskPlayed = 0

    /// Called on state changes worth surfacing (playing/idle); the app
    /// controller repaints the icon from /health anyway, so this is a hint,
    /// not the source of truth.
    var onActivity: (@Sendable (Bool) -> Void)?

    init(
        base: URL,
        token: String?,
        audioOutput: SegmentAudioOutput? = nil,
        outputDeviceApplier: SegmentOutputDeviceApplying =
            AVAudioEngineOutputDeviceApplier()
    ) {
        self.base = base
        self.token = token
        self.audioOutput = audioOutput
        self.outputDeviceApplier = outputDeviceApplier
        let config = URLSessionConfiguration.ephemeral
        // Above the long-poll timeout so the daemon's 204, not the client,
        // ends a quiet poll.
        config.timeoutIntervalForRequest = SegmentPoll.timeout + 10
        self.session = URLSession(configuration: config)
        if audioOutput == nil {
            engine.attach(node)
            engine.attach(timePitch)
        }
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.pollOnce()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.currentTask?.cancel()
            self.flushLocked()
            if let output = self.audioOutput {
                output.shutdown()
            } else {
                self.engine.stop()
            }
        }
    }

    /// Local, immediate pause: the daemon's pause flag can't stop audio the
    /// player already fetched. The app calls this from the menu and when it
    /// notices the local channel's paused flag flip on /health.
    func setPaused(_ paused: Bool) {
        queue.async {
            guard paused != self.userPaused else { return }
            self.userPaused = paused
            if paused {
                if let output = self.audioOutput {
                    output.pause()
                } else {
                    self.node.pause()
                }
            } else if let output = self.audioOutput {
                output.resumeIfRunning()
            } else if self.engine.isRunning {
                self.node.play()
            }
        }
    }

    /// Pitch-preserving playback rate, clamped like the extension's.
    func setRate(_ rate: Double) {
        queue.async {
            let clamped = Float(LocalSpeakingRate.clamped(rate))
            if let output = self.audioOutput {
                output.setRate(clamped)
            } else {
                self.timePitch.rate = clamped
            }
        }
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.outputDeviceApplier.apply(
                        deviceID: deviceID,
                        to: self.engine,
                        shouldRun: self.running
                            && self.connectedFormat != nil)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Poll loop

    private func pollOnce() {
        guard running else { return }
        var request = URLRequest(url: poll.url(base: base))
        if let token {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        currentTaskPlayed = poll.played
        let task = session.dataTask(with: request) {
            [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.currentTask = nil
                self.handle(
                    data: data,
                    response: response,
                    error: error
                )
            }
        }
        currentTask = task
        task.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?) {
        guard running else { return }
        if let error {
            // A cancel means the played cursor advanced mid-poll: re-poll
            // now so the daemon sees it. Anything else is the daemon
            // restarting or unreachable; keep trying quietly.
            let backoff = (error as? URLError)?.code == .cancelled ? 0.0 : 1.0
            schedulePoll(after: backoff)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            schedulePoll(after: 1.0)
            return
        }
        switch http.statusCode {
        case 200, 204:
            let epoch = http.value(
                forHTTPHeaderField: "X-Epoch"
            ).flatMap(Int.init)
            let seq = http.value(
                forHTTPHeaderField: "X-Seq"
            ).flatMap(Int.init)
            let action = poll.handle(
                status: http.statusCode,
                epoch: epoch,
                seq: seq
            )
            switch action {
            case .flush:
                flushLocked()
            case .segment(let seq, let flushFirst):
                if flushFirst { flushLocked() }
                if let data { scheduleSegment(data, seq: seq) }
            case .none:
                break
            }
            schedulePoll(after: 0)
        case 404:
            // Daemon-played local channel (no --local-player client): no
            // stream to play. Keep checking slowly; a restart in client
            // mode brings the stream up without restarting the app.
            schedulePoll(after: 5.0)
        default:
            // 401 bad token / 400: retrying won't change the answer fast;
            // crawl so the log doesn't spin.
            NSLog("wren player: /segment returned \(http.statusCode)")
            schedulePoll(after: 30.0)
        }
    }

    private func schedulePoll(after delay: TimeInterval) {
        guard running else { return }
        if delay == 0 {
            pollOnce()
        } else {
            queue.asyncAfter(deadline: .now() + delay) { self.pollOnce() }
        }
    }

    // MARK: - Audio

    private func scheduleSegment(_ data: Data, seq: Int) {
        if let output = audioOutput {
            let epoch = localEpoch
            let scheduled = output.schedule(data) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.segmentFinished(seq, epoch: epoch)
                }
            }
            guard scheduled else {
                NSLog("wren player: undecodable segment \(seq)")
                return
            }
            if !userPaused {
                output.resumeIfRunning()
            }
            onActivity?(true)
            return
        }
        guard let buffer = Self.decodeWav(data) else {
            NSLog("wren player: undecodable segment \(seq)")
            return
        }
        do {
            try ensureGraph(for: buffer.format)
        } catch {
            NSLog("wren player: audio engine failed: \(error)")
            return
        }
        let epoch = localEpoch
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            guard let self else { return }
            self.queue.async { self.segmentFinished(seq, epoch: epoch) }
        }
        if !userPaused { node.play() }
        onActivity?(true)
    }

    private func segmentFinished(_ seq: Int, epoch: Int) {
        // Callbacks also fire when a flush stops the node; only genuine
        // playback (same local epoch) moves the played cursor.
        guard epoch == localEpoch else { return }
        if poll.notePlayed(seq), let task = currentTask,
           currentTaskPlayed < poll.played {
            task.cancel() // carry the fresh cursor to the daemon now
        }
        onActivity?(false)
    }

    private func flushLocked() {
        localEpoch += 1
        // stop() drops everything scheduled; play() re-arms the node so the
        // next scheduled buffer starts without an explicit restart.
        if let output = audioOutput {
            output.flush()
        } else {
            node.stop()
        }
        onActivity?(false)
    }

    private func ensureGraph(for format: AVAudioFormat) throws {
        if connectedFormat != format {
            // Sample rate/channel change between segments (voice or backend
            // swap): rewire the graph. Rare, so the hard cut is fine.
            node.stop()
            engine.connect(node, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// AVAudioFile only reads from disk, so the wav lands in a temp file
    /// just long enough to decode.
    private static func decodeWav(_ data: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wren-seg-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { return nil }
            try file.read(into: buffer)
            return buffer
        } catch {
            NSLog("wren player: wav decode failed: \(error)")
            return nil
        }
    }
}
