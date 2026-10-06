import ArgumentParser
import Foundation
import XCTest
@testable import wren

final class EndpointTests: XCTestCase {
    func testHostPrecedenceFlagEnvSavedDefault() {
        let env = ["WREN_HOST": "env:2"]
        XCTAssertEqual(
            Endpoint.resolveHost(flag: "flag:1", environment: env,
                                 saved: "saved:3"),
            "flag:1"
        )
        XCTAssertEqual(
            Endpoint.resolveHost(flag: nil, environment: env,
                                 saved: "saved:3"),
            "env:2"
        )
        XCTAssertEqual(
            Endpoint.resolveHost(flag: nil, environment: [:],
                                 saved: "saved:3"),
            "saved:3"
        )
        XCTAssertEqual(
            Endpoint.resolveHost(flag: nil, environment: [:], saved: nil),
            Endpoint.defaultHost
        )
        XCTAssertEqual(
            Endpoint.resolveHost(flag: "", environment: ["WREN_HOST": ""],
                                 saved: "saved:3"),
            "saved:3",
            "empty overrides fall through"
        )
    }

    func testNormalizeStripsSchemeAndSlash() {
        XCTAssertEqual(Endpoint.normalize(" http://box:8765/ "), "box:8765")
        XCTAssertEqual(Endpoint.normalize("HTTPS://box"), "box")
        XCTAssertEqual(Endpoint.normalize("box:1"), "box:1")
    }

    func testSystemStorePersistsHostInDefaults() {
        let suite = "wren-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SystemEndpointStore(defaults: defaults)
        store.savedHost = "box:9"
        XCTAssertEqual(
            SystemEndpointStore(defaults: defaults).savedHost,
            "box:9"
        )
        store.savedHost = ""
        XCTAssertNil(defaults.string(forKey: SystemEndpointStore.hostKey))
    }

    func testCLIClientUsesSavedEndpointUnlessOverridden() throws {
        let saved = MemoryEndpointStore(host: "saved:1")
        let options = try ClientOptions.parse([])
        let client = options.client(environment: [:], saved: saved)
        XCTAssertEqual(client.host, "saved:1")

        let flagged = try ClientOptions.parse(["--host", "flag:2"])
        let other = flagged.client(environment: [:], saved: saved)
        XCTAssertEqual(other.host, "flag:2")
    }
}

final class ClientChannelTests: XCTestCase {
    func testSanitizedHostnameChannel() {
        XCTAssertEqual(
            ClientChannel.defaultChannel(hostname: "Studio.local"),
            "mac-studio"
        )
        XCTAssertEqual(
            ClientChannel.defaultChannel(hostname: "Che's MacBook Pro"),
            "mac-ches-macbook-pro"
        )
        XCTAssertEqual(
            ClientChannel.defaultChannel(hostname: "box.tail1.ts.net"),
            "mac-box"
        )
        XCTAssertEqual(ClientChannel.defaultChannel(hostname: "ÉÉ"),
                       "mac-unknown")
    }

    func testChannelAlwaysMatchesContractRegex() throws {
        let regex = try NSRegularExpression(pattern: "^[a-z0-9_-]{1,32}$")
        for host in [
            String(repeating: "a", count: 100), "UPPER_case-1", "a b\tc",
            "", "...", "x!@#$%^&*()y",
        ] {
            let channel = ClientChannel.defaultChannel(hostname: host)
            let range = NSRange(channel.startIndex..., in: channel)
            XCTAssertNotNil(
                regex.firstMatch(in: channel, range: range),
                "\(host) -> \(channel)"
            )
            XCTAssertTrue(channel.hasPrefix("mac-"))
        }
    }
}

final class ActivityMonitorTests: XCTestCase {
    func testClaimsOnIdleDropThrottledToTwoSeconds() {
        let monitor = ActivityMonitor(idleSeconds: { 0 })
        let count = Counter()
        monitor.onActivityDetected = { count.increment() }
        let t0 = Date()

        monitor.poll(currentSeconds: 10, now: t0)
        XCTAssertEqual(count.value, 0, "first sample only primes")
        monitor.poll(currentSeconds: 11, now: t0)
        XCTAssertEqual(count.value, 0, "idle rising is no input")
        monitor.poll(currentSeconds: 0.1, now: t0)
        XCTAssertEqual(count.value, 1)
        monitor.poll(currentSeconds: 0.05, now: t0.addingTimeInterval(1.9))
        XCTAssertEqual(count.value, 1, "throttled")
        monitor.poll(currentSeconds: 0.5, now: t0.addingTimeInterval(2.5))
        XCTAssertEqual(count.value, 1, "rising again")
        monitor.poll(currentSeconds: 0.01, now: t0.addingTimeInterval(2.6))
        XCTAssertEqual(count.value, 2)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

final class CLITests: XCTestCase {
    func testSayAndYellSendNoChannel() throws {
        let say = try Say.parse(["hello", "there", "--speed", "1.5"])
        let body = try say.speak.body(append: true)
        XCTAssertEqual(body.text, "hello there")
        XCTAssertEqual(body.append, true)
        XCTAssertEqual(body.speed, 1.5)
        XCTAssertNil(body.channel)

        let yell = try Yell.parse(["now", "--raw"])
        let loud = try yell.speak.body(append: false)
        XCTAssertEqual(loud.append, false)
        XCTAssertEqual(loud.raw, true)
        XCTAssertNil(loud.channel)
    }

    func testSpeedOutOfRangeRejected() {
        XCTAssertThrowsError(try Say.parse(["x", "--speed", "4"]))
    }

    func testStopAllFlag() throws {
        XCTAssertTrue(try Stop.parse(["--all"]).all)
        XCTAssertFalse(try Stop.parse([]).all)
    }

    func testCommandTreeHasEveryVerb() throws {
        for args in [
            ["pause"], ["resume"], ["voices"], ["voice", "use", "x"],
            ["voice", "rename", "x", "New"], ["voice", "delete", "x"],
            ["effects", "on"], ["status"], ["state", "--json"], ["doctor"],
            ["voice", "add", "x", "--audio", "a.wav", "--transcript", "t"],
        ] {
            XCTAssertNoThrow(try Wren.parseAsRoot(args), "\(args)")
        }
    }

    func testStateRequiresJSON() {
        XCTAssertThrowsError(try Wren.parseAsRoot(["state"]))
    }

    func testVoiceAddNeedsExactlyOneTranscriptSource() {
        XCTAssertThrowsError(try VoiceAdd.parse(["x", "--audio", "a.wav"]))
        XCTAssertThrowsError(try VoiceAdd.parse([
            "x", "--audio", "a.wav", "--transcript", "t",
            "--transcript-file", "f",
        ]))
    }

    func testSpeakInputFromStdin() throws {
        let text = try SpeakInput.resolve(
            arguments: [],
            stdinIsTTY: false,
            readStdin: { Data("  piped\n".utf8) }
        )
        XCTAssertEqual(text, "piped")
        XCTAssertThrowsError(try SpeakInput.resolve(
            arguments: [],
            stdinIsTTY: true
        ))
    }

    func testStatusReportListsChannels() {
        let state = DaemonStateResponse(
            ready: true,
            backend: "qwentts",
            activeVoice: "c3po",
            effects: true,
            activeClient: ClientInfo(channel: "mac-a", label: "A"),
            channels: [
                "mac-a": ChannelInfo(
                    label: "A",
                    speaking: true,
                    paused: false,
                    pending: 3
                ),
            ]
        )
        let lines = StatusReport.lines(host: "h:1", state: state)
        XCTAssertTrue(lines.contains("active client: A"))
        XCTAssertTrue(lines.contains("effects:       on"))
        XCTAssertTrue(lines.contains(
            "channel:       mac-a (A): speaking, 3 pending"
        ))
    }
}
