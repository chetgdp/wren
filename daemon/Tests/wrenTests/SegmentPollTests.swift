import XCTest
@testable import wren

final class SegmentPollTests: XCTestCase {
    func testUrlCarriesCursors() throws {
        var poll = SegmentPoll()
        _ = poll.handle(status: 200, epoch: 1, seq: 3)
        _ = poll.notePlayed(2)
        let base = URL(string: "http://127.0.0.1:8765")!
        let url = poll.url(base: base)
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/segment")
        let pairs = (components.queryItems ?? []).map {
            ($0.name, $0.value)
        }
        let query = Dictionary(uniqueKeysWithValues: pairs)
        XCTAssertEqual(query["after"], "3")
        XCTAssertEqual(query["played"], "2")
        XCTAssertEqual(query["timeout"], "20")
    }

    func testFirstResponseNeverFlushes() {
        // Epoch 0 vs "no epoch seen yet" must be distinguishable, or every
        // fresh player start would begin with a spurious flush.
        var poll = SegmentPoll()
        XCTAssertEqual(
            poll.handle(status: 204, epoch: 5, seq: nil),
            .none)
        XCTAssertEqual(
            poll.handle(status: 200, epoch: 5, seq: 1),
            .segment(seq: 1, flushFirst: false))
    }

    func testEpochChangeFlushes() {
        var poll = SegmentPoll()
        _ = poll.handle(status: 200, epoch: 1, seq: 1)
        // Preemption noticed on a quiet poll: drop local audio, keep polling.
        XCTAssertEqual(poll.handle(status: 204, epoch: 2, seq: nil), .flush)
        // Preemption arriving with the first segment of the new epoch:
        // flush, then schedule that segment.
        XCTAssertEqual(
            poll.handle(status: 200, epoch: 3, seq: 7),
            .segment(seq: 7, flushFirst: true))
        XCTAssertEqual(poll.after, 7)
    }

    func testPlayedCursorIsMonotonic() {
        var poll = SegmentPoll()
        XCTAssertTrue(poll.notePlayed(3))
        XCTAssertFalse(poll.notePlayed(3))
        XCTAssertFalse(poll.notePlayed(1))
        XCTAssertEqual(poll.played, 3)
    }
}

final class SegmentPollChannelTests: XCTestCase {
    func testUrlCarriesChannel() throws {
        let poll = SegmentPoll(channel: "mac-studio")
        let url = poll.url(base: URL(string: "http://h:1")!)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        XCTAssertTrue(items.contains(
            URLQueryItem(name: "channel", value: "mac-studio")
        ))
    }
}
