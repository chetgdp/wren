import XCTest
@testable import wren

final class HostResolutionTests: XCTestCase {
    func testFlagBeatsEnvAndDefault() {
        let host = DaemonClient.resolveHost(
            flag: "10.0.0.5:9000", environment: ["WREN_HOST": "env.host:1234"])
        XCTAssertEqual(host, "10.0.0.5:9000")
    }

    func testEnvBeatsDefault() {
        let host = DaemonClient.resolveHost(
            flag: nil, environment: ["WREN_HOST": "env.host:1234"])
        XCTAssertEqual(host, "env.host:1234")
    }

    func testDefaultLoopback() {
        XCTAssertEqual(DaemonClient.resolveHost(flag: nil, environment: [:]),
                       "127.0.0.1:8765")
    }

    func testTokenFlagBeatsEnv() {
        XCTAssertEqual(
            DaemonClient.resolveToken(flag: "abc", environment: ["WREN_TOKEN": "xyz"]),
            "abc")
        XCTAssertEqual(
            DaemonClient.resolveToken(flag: nil, environment: ["WREN_TOKEN": "xyz"]),
            "xyz")
        XCTAssertNil(DaemonClient.resolveToken(flag: nil, environment: [:]))
    }
}

final class RequestBuildingTests: XCTestCase {
    let client = DaemonClient(host: "127.0.0.1:9999", token: nil)

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testHealthRequest() throws {
        let request = try client.request(path: "/health")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9999/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testSpeakBodyMinimal() throws {
        let request = try client.postRequest(
            path: "/speak", body: SpeakRequest(text: "hello"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "application/json")
        let body = try json(request)
        XCTAssertEqual(body["text"] as? String, "hello")
        // Absent options must stay off the wire so daemon defaults apply.
        XCTAssertNil(body["append"])
        XCTAssertNil(body["raw"])
        XCTAssertNil(body["speed"])
    }

    func testSayAlwaysQueues() throws {
        // `wren say` must never preempt another caller, so append is
        // unconditional and there is no flag to turn it off.
        let plain = try Say.parse(["hello"])
        XCTAssertEqual(plain.body.append, true)
        XCTAssertThrowsError(try Say.parse(["hello", "--append"]))

        let request = try client.postRequest(path: "/speak", body: plain.body)
        let body = try json(request)
        XCTAssertEqual(body["append"] as? Bool, true)
    }

    func testYellPreempts() throws {
        // `wren yell` is the one deliberate preemption path: append stays off
        // the wire so the daemon's default (cut current playback) applies.
        let plain = try Yell.parse(["move now"])
        XCTAssertNil(plain.body.append)

        let request = try client.postRequest(path: "/speak", body: plain.body)
        let body = try json(request)
        XCTAssertEqual(body["text"] as? String, "move now")
        XCTAssertNil(body["append"])
        XCTAssertNil(body["raw"])
        XCTAssertNil(body["speed"])

        let full = try Yell.parse(["hi", "--raw", "--speed", "1.5"])
        let fullBody = try json(client.postRequest(path: "/speak", body: full.body))
        XCTAssertNil(fullBody["append"])
        XCTAssertEqual(fullBody["raw"] as? Bool, true)
        XCTAssertEqual(fullBody["speed"] as? Double, 1.5)
    }

    func testSpeakBodyFull() throws {
        let request = try client.postRequest(
            path: "/speak",
            body: SpeakRequest(text: "hi", append: true, raw: true, speed: 1.5))
        let body = try json(request)
        XCTAssertEqual(body["append"] as? Bool, true)
        XCTAssertEqual(body["raw"] as? Bool, true)
        XCTAssertEqual(body["speed"] as? Double, 1.5)
    }

    func testBearerTokenHeader() throws {
        let authed = DaemonClient(host: "127.0.0.1:9999", token: "s3cret")
        let request = try authed.request(path: "/health")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer s3cret")
    }

    func testConfigUpdateEncodesTypedValues() throws {
        let speed = try json(client.postRequest(
            path: "/config", body: ConfigUpdate.parsing(key: "speed", value: "1.4")))
        XCTAssertEqual(speed["speed"] as? Double, 1.4)
        XCTAssertEqual(speed.count, 1)

        let fx = try json(client.postRequest(
            path: "/config", body: ConfigUpdate.parsing(key: "fx", value: "true")))
        XCTAssertEqual(fx["fx"] as? Bool, true)

        let port = try json(client.postRequest(
            path: "/config", body: ConfigUpdate.parsing(key: "port", value: "9001")))
        XCTAssertEqual(port["port"] as? Int, 9001)

        // The daemon's key is snake_case; the encoder must translate it.
        let dir = try json(client.postRequest(
            path: "/config",
            body: ConfigUpdate.parsing(key: "voices_dir", value: "/tmp/v")))
        XCTAssertEqual(dir["voices_dir"] as? String, "/tmp/v")
    }

    func testConfigUpdateRejectsBadValues() {
        XCTAssertThrowsError(try ConfigUpdate.parsing(key: "speed", value: "fast"))
        XCTAssertThrowsError(try ConfigUpdate.parsing(key: "fx", value: "yes"))
        XCTAssertThrowsError(try ConfigUpdate.parsing(key: "port", value: "80x"))
        XCTAssertThrowsError(try ConfigUpdate.parsing(key: "volume", value: "1"))
    }

    func testHealthDecodesSnakeCasePayload() throws {
        let payload = Data("""
        {"ok": true, "ready": true, "model": "m", "playback": "local",
         "pending": 2, "speaking": true, "paused": false,
         "block": [1, 3], "speed": 1.5}
        """.utf8)
        let health = try DaemonClient.decoder.decode(HealthResponse.self, from: payload)
        XCTAssertTrue(health.ready)
        XCTAssertEqual(health.pending, 2)
        XCTAssertEqual(health.block, [1, 3])
        XCTAssertEqual(health.speed, 1.5)
    }

    func testConfigPayloadDecodesPersistFields() throws {
        let payload = Data("""
        {"voice": null, "voices_dir": null, "speed": 1.0, "fx": false,
         "port": 8765, "backend": "auto", "restart_required": true,
         "persisted": false, "persist_error": "disk full"}
        """.utf8)
        let config = try DaemonClient.decoder.decode(ConfigPayload.self, from: payload)
        XCTAssertTrue(config.restartRequired)
        XCTAssertEqual(config.persisted, false)
        XCTAssertEqual(config.persistError, "disk full")
    }
}
