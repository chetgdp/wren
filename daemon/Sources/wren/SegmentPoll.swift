import Foundation

/// Pure bookkeeping for the /segment long-poll loop: URL construction and
/// the epoch/seq decisions, separated from AVFoundation so they are
/// unit-testable. The daemon's contract: audio/wav with X-Seq/X-Epoch/
/// X-Block headers, 204 + X-Epoch on a quiet poll, and an epoch change
/// meaning "playback was preempted; drop everything you have scheduled".
struct SegmentPoll {
    /// Matches the daemon's SEGMENT_POLL_TIMEOUT; the played-report grace
    /// window is derived from it server-side, so polling longer would risk
    /// being declared dead mid-poll.
    static let timeout = 20.0

    private(set) var after = 0
    private(set) var played = 0
    private(set) var epoch: Int?

    func url(base: URL) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent("segment"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "played", value: String(played)),
            URLQueryItem(name: "timeout", value: String(Int(Self.timeout))),
        ]
        return components.url!
    }

    enum Outcome: Equatable {
        /// Drop locally scheduled audio (epoch changed), then continue.
        case flush
        /// Schedule this segment; flushFirst when the epoch changed on the
        /// same response that carried it.
        case segment(seq: Int, flushFirst: Bool)
        /// Quiet poll or unchanged epoch; just poll again.
        case none
    }

    /// Digest one poll response. status 204 carries only an epoch; 200
    /// carries a segment. Any other status is the caller's problem.
    mutating func handle(status: Int, epoch newEpoch: Int?, seq: Int?) -> Outcome {
        let preempted = epoch != nil && newEpoch != nil && newEpoch != epoch
        if let newEpoch { epoch = newEpoch }
        guard status == 200, let seq else {
            return preempted ? .flush : .none
        }
        after = max(after, seq)
        return .segment(seq: seq, flushFirst: preempted)
    }

    /// A locally finished segment moves the played cursor; the loop aborts
    /// an in-flight poll whose snapshot is older so the machine queue sees
    /// progress promptly (turn handoff hangs on this report).
    mutating func notePlayed(_ seq: Int) -> Bool {
        guard seq > played else { return false }
        played = seq
        return true
    }

    /// A rebuilt player resumes from the persisted cursor: segments fetched
    /// but never finished must be re-fetched, not skipped.
    mutating func resume(fromPlayed seq: Int) {
        played = max(played, seq)
        after = max(after, seq)
    }
}
