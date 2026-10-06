import CoreGraphics
import Foundation

/// Detects local user input by watching the HID idle timer: when the
/// seconds since the last event drop, someone touched this Mac. Polling
/// the counter needs no Accessibility or Input Monitoring permission,
/// unlike an event tap.
final class ActivityMonitor: @unchecked Sendable {
    static let throttle: TimeInterval = 2.0
    private static let pollInterval: DispatchTimeInterval = .milliseconds(500)

    private let queue = DispatchQueue(label: "wren.activity-monitor")
    private let idleSeconds: @Sendable () -> CFTimeInterval
    private var lastSeconds: CFTimeInterval?
    private var lastClaim: Date?
    private var timer: DispatchSourceTimer?
    var onActivityDetected: (@Sendable () -> Void)?

    init(
        idleSeconds: @escaping @Sendable () -> CFTimeInterval = {
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: CGEventType(rawValue: ~0)!
            )
        }
    ) {
        self.idleSeconds = idleSeconds
    }

    func start() {
        queue.async {
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.poll(currentSeconds: self.idleSeconds(), now: Date())
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// One sample. Fires at most once per `throttle` so a burst of typing
    /// becomes one claim request, not one per poll.
    func poll(currentSeconds: CFTimeInterval, now: Date) {
        defer { lastSeconds = currentSeconds }
        guard let previous = lastSeconds, currentSeconds < previous else {
            return
        }
        if let lastClaim, now.timeIntervalSince(lastClaim) < Self.throttle {
            return
        }
        lastClaim = now
        onActivityDetected?()
    }
}
