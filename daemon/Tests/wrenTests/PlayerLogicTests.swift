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

    func testResumeNeverRewinds() {
        var poll = SegmentPoll()
        _ = poll.handle(status: 200, epoch: 1, seq: 9)
        _ = poll.notePlayed(9)
        poll.resume(fromPlayed: 4)
        XCTAssertEqual(poll.after, 9)
        XCTAssertEqual(poll.played, 9)
    }
}

final class ServeSpawnTests: XCTestCase {
    private let paths = WrenPaths(
        resources: URL(
            fileURLWithPath:
                "/Applications/Wren.app/Contents/Resources"),
        appSupport: URL(
            fileURLWithPath:
                "/Users/x/Library/Application Support/voice-ml"))

    func testSpawnUsesOnlyBundleAndAppSupportPaths() {
        let arguments = DaemonManager.serveArguments(
            paths: paths,
            settingsExist: true)
        XCTAssertEqual(
            arguments[0],
            "/Applications/Wren.app/Contents/Resources/server/serve.py")
        XCTAssertTrue(arguments.contains("--local-player"))
        XCTAssertTrue(arguments.contains("client"))
        XCTAssertTrue(arguments.contains(
            "/Applications/Wren.app/Contents/Resources/engine/tts-server"))
        XCTAssertTrue(arguments.contains(
            "/Users/x/Library/Application Support/voice-ml/models/"
                + "qwen-talker-1.7b-base-Q8_0.gguf"))
        XCTAssertFalse(arguments.contains("--initial-voice"))
        XCTAssertFalse(arguments.contains("-r"))
    }

    func testMissingSettingsAddsInitialVoiceID() throws {
        let arguments = DaemonManager.serveArguments(
            paths: paths,
            settingsExist: false)
        let flag = try XCTUnwrap(
            arguments.firstIndex(of: "--initial-voice"))

        XCTAssertEqual(arguments[flag + 1], "c3po_god")
        XCTAssertFalse(arguments.contains("-r"))
    }
}

final class HealthChannelsDecodingTests: XCTestCase {
    func testDecodesChannelMap() throws {
        let body = Data("""
        {"ok": true, "ready": true, "model": "m", "playback": "client",
         "pending": 1, "speaking": true, "paused": false, "block": null,
         "speed": 1.4,
         "channels": {"local": {"pending": 0, "speaking": false,
                                "paused": false, "block": null,
                                "active": false},
                      "extension": {"pending": 1, "speaking": true,
                                    "paused": false, "block": [2, 3],
                                    "active": true}}}
        """.utf8)
        let health = try DaemonClient.decoder.decode(
            HealthResponse.self,
            from: body)
        XCTAssertEqual(health.channels?["extension"]?.block, [2, 3])
        XCTAssertEqual(health.channels?["local"]?.active, false)
    }

    func testChannelsAbsentStillDecodes() throws {
        // A pre-channels daemon (or Linux box on an older commit) must not
        // break the app's health poll.
        let body = Data("""
        {"ok": true, "ready": false, "model": "m", "playback": "local",
         "pending": 0, "speaking": false, "paused": false}
        """.utf8)
        let health = try DaemonClient.decoder.decode(
            HealthResponse.self,
            from: body)
        XCTAssertNil(health.channels)
    }
}
