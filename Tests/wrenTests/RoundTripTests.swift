import XCTest
@testable import wren

/// End-to-end client tests against StubServer on an ephemeral port. These
/// exercise URLSession, the coders, and the error mapping together.
final class RoundTripTests: XCTestCase {
    func testSpeakRoundTrip() async throws {
        let server = try StubServer { _ in (200, #"{"queued": 3}"#) }
        defer { server.stop() }

        let client = DaemonClient(host: "127.0.0.1:\(server.port)", token: "tok")
        let response: SpeakResponse = try await client.post(
            "/speak", body: SpeakRequest(text: "hello there", speed: 2.0))
        XCTAssertEqual(response.queued, 3)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/speak")
        XCTAssertEqual(request.headers["authorization"], "Bearer tok")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "hello there")
        XCTAssertEqual(body["speed"] as? Double, 2.0)
    }

    func testHealthRoundTrip() async throws {
        let server = try StubServer { _ in
            (200, #"""
            {"ok": true, "ready": true, "model": "test-model",
             "playback": "local", "pending": 1, "speaking": true,
             "paused": false, "block": null, "speed": 1.2}
            """#)
        }
        defer { server.stop() }

        let client = DaemonClient(host: "127.0.0.1:\(server.port)", token: nil)
        let health: HealthResponse = try await client.get("/health")
        XCTAssertEqual(health.model, "test-model")
        XCTAssertTrue(health.speaking)
        XCTAssertNil(health.block)
        XCTAssertEqual(health.speed, 1.2)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/health")
        XCTAssertNil(request.headers["authorization"])
    }

    func testConfigPostRoundTrip() async throws {
        let server = try StubServer { _ in
            (200, #"""
            {"voice": "boss", "voices_dir": "/v", "speed": 1.4, "fx": false,
             "port": 8765, "backend": "auto", "restart_required": false,
             "persisted": true}
            """#)
        }
        defer { server.stop() }

        let client = DaemonClient(host: "127.0.0.1:\(server.port)", token: nil)
        let payload: ConfigPayload = try await client.post(
            "/config", body: ConfigUpdate(speed: 1.4))
        XCTAssertEqual(payload.speed, 1.4)
        XCTAssertEqual(payload.persisted, true)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/config")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), #"{"speed":1.4}"#)
    }

    func testDaemonErrorMessageSurfaces() async throws {
        let server = try StubServer { _ in (400, #"{"error": "missing text"}"#) }
        defer { server.stop() }

        let client = DaemonClient(host: "127.0.0.1:\(server.port)", token: nil)
        do {
            let _: SpeakResponse = try await client.post(
                "/speak", body: SpeakRequest(text: ""))
            XCTFail("expected an error")
        } catch let error as DaemonError {
            guard case .http(let status, let message) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(message, "missing text")
        }
    }

    func testConnectionRefusedMapsToNotRunning() async throws {
        // Bind then immediately release an ephemeral port: nothing listens
        // there, so the connect is refused.
        let probe = try StubServer { _ in (200, "{}") }
        let port = probe.port
        probe.stop()

        let client = DaemonClient(host: "127.0.0.1:\(port)", token: nil)
        do {
            let _: HealthResponse = try await client.get("/health")
            XCTFail("expected an error")
        } catch let error as DaemonError {
            guard case .notRunning(let host) = error else {
                return XCTFail("expected .notRunning, got \(error)")
            }
            XCTAssertEqual(host, "127.0.0.1:\(port)")
            XCTAssertEqual("\(error)",
                           "daemon not running on 127.0.0.1:\(port) - is it started?")
        }
    }
}
