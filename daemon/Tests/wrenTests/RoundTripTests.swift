import XCTest
@testable import wren

/// End-to-end client tests against StubServer on an ephemeral port. These
/// exercise URLSession, the coders, and the error mapping together.
final class RoundTripTests: XCTestCase {
    func testSpeakRoundTrip() async throws {
        let server = try StubServer { _ in (200, #"{"queued": 3}"#) }
        defer { server.stop() }

        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: "tok")
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


    func testDaemonErrorMessageSurfaces() async throws {
        let server = try StubServer { _ in
            (400, #"{"error": "missing text"}"#)
        }
        defer { server.stop() }

        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil)
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
            XCTAssertEqual(
                "\(error)",
                "daemon not running on 127.0.0.1:\(port) "
                    + "- is it started?")
        }
    }
}

final class ManagementRoundTripTests: XCTestCase {
    private let operationJSON = #"""
    {
      "id": "request-1",
      "kind": "activate_voice",
      "phase": "preparing",
      "target": "wintermute",
      "progress": null,
      "error": null
    }
    """#

    func testTypedManagementReadsUseExactRoutes() async throws {
        let server = try StubServer { request in
            switch request.path {
            case "/meta":
                return (200, #"""
                {
                  "service": "wren",
                  "protocol_version": 2,
                  "instance_id": "instance-1",
                  "started_at": "2026-08-07T01:00:00Z",
                  "capabilities": ["state-v2"]
                }
                """#)
            case "/state":
                return (200, Self.stateJSON)
            case "/voices":
                return (200, #"""
                {
                  "revision": 9,
                  "voices": [{
                    "id": "c3po_god",
                    "display_name": "C-3PO",
                    "status": "ready",
                    "issues": []
                  }]
                }
                """#)
            case "/operations/request-1":
                return (200, self.operationJSON)
            default:
                return (404, #"""
                {"error":{"code":"not_found","message":"Not found."}}
                """#)
            }
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: "token")

        let meta = try await client.meta()
        let state = try await client.state()
        let voices = try await client.voices()
        let operation = try await client.operation(requestID: "request-1")

        XCTAssertEqual(meta.instanceID, "instance-1")
        XCTAssertEqual(state.revision, 42)
        XCTAssertEqual(voices.voices.first?.displayName, "C-3PO")
        XCTAssertEqual(operation.phase, .preparing)
        XCTAssertEqual(
            server.requests.map(\.path),
            [
                "/meta",
                "/state",
                "/voices",
                "/operations/request-1",
            ])
        for request in server.requests {
            XCTAssertEqual(
                request.headers["authorization"],
                "Bearer token")
            XCTAssertNil(request.headers["origin"])
        }
    }

    func testTypedMutationsUseMethodsHeadersAndBodies() async throws {
        let operationJSON = self.operationJSON
        let server = try StubServer { _ in (202, operationJSON) }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil)

        _ = try await client.activateVoice(
            "wintermute",
            requestID: "request-1")
        _ = try await client.updateVoice(
            id: "wintermute",
            update: UpdateVoiceRequest(displayName: "Neuromancer"),
            requestID: "request-2")
        _ = try await client.deleteVoice(
            id: "wintermute",
            requestID: "request-3")

        XCTAssertEqual(
            server.requests.map(\.method),
            ["POST", "PATCH", "DELETE"])
        XCTAssertEqual(
            server.requests.map(\.path),
            [
                "/voices/activate",
                "/voices/wintermute",
                "/voices/wintermute",
            ])
        XCTAssertEqual(
            server.requests.map {
                $0.headers["idempotency-key"]
            },
            ["request-1", "request-2", "request-3"])

        let activation = try Self.json(server.requests[0].body)
        XCTAssertEqual(
            activation["voice"] as? String,
            "wintermute")
        let update = try Self.json(server.requests[1].body)
        XCTAssertEqual(
            update["display_name"] as? String,
            "Neuromancer")
        XCTAssertTrue(server.requests[2].body.isEmpty)
    }

    func testTypedPlaybackKeepsEmptyJSONBody() async throws {
        let server = try StubServer { request in
            switch request.path {
            case "/pause":
                return (200, #"{"ok":true,"paused":true}"#)
            case "/resume":
                return (200, #"{"ok":true,"paused":false}"#)
            case "/stop":
                return (200, #"{"ok":true}"#)
            default:
                return (404, #"{"error":"not found"}"#)
            }
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil)

        let paused = try await client.pause()
        let resumed = try await client.resume()
        let stopped = try await client.stopSpeaking()
        XCTAssertTrue(paused.paused)
        XCTAssertFalse(resumed.paused)
        XCTAssertTrue(stopped.ok)

        XCTAssertEqual(
            server.requests.map(\.method),
            ["POST", "POST", "POST"])
        XCTAssertEqual(
            server.requests.map {
                String(data: $0.body, encoding: .utf8)
            },
            ["{}", "{}", "{}"])
    }

    func testAuthorizationAndOriginFailuresAreDistinct() async throws {
        let authorization = try StubServer { _ in
            (401, #"""
            {
              "error": {
                "code": "authorization_required",
                "message": "Token required.",
                "detail": "Authorization header missing",
                "recoverable": true
              }
            }
            """#)
        }
        defer { authorization.stop() }
        let unauthorized = DaemonClient(
            host: "127.0.0.1:\(authorization.port)",
            token: nil)
        do {
            _ = try await unauthorized.meta()
            XCTFail("expected authorization failure")
        } catch let error as DaemonError {
            guard case .authorization(let status, let detail) = error else {
                return XCTFail("expected authorization, got \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(detail?.code, "authorization_required")
            XCTAssertEqual(
                detail?.detail,
                .string("Authorization header missing"))
            XCTAssertEqual(detail?.recoverable, true)
        }

        let origin = try StubServer { _ in
            (403, #"""
            {
              "error": {
                "code": "origin_not_allowed",
                "message": "Origin rejected."
              }
            }
            """#)
        }
        defer { origin.stop() }
        let forbidden = DaemonClient(
            host: "127.0.0.1:\(origin.port)",
            token: nil)
        do {
            _ = try await forbidden.meta()
            XCTFail("expected Origin failure")
        } catch let error as DaemonError {
            guard case .originAccess(let status, let detail) = error else {
                return XCTFail("expected Origin failure, got \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(detail?.code, "origin_not_allowed")
        }
    }

    func testStructuredManagementFailurePreservesEnvelope() async throws {
        let server = try StubServer { _ in
            (409, #"""
            {
              "error": {
                "code": "request_id_conflict",
                "message": "Request ID was already used.",
                "detail": "POST /voices/activate",
                "recoverable": false
              }
            }
            """#)
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil)
        do {
            _ = try await client.activateVoice(
                "wintermute",
                requestID: "request-1")
            XCTFail("expected management failure")
        } catch let error as DaemonError {
            guard case .management(let status, let detail) = error else {
                return XCTFail("expected management failure, got \(error)")
            }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(detail.code, "request_id_conflict")
            XCTAssertEqual(detail.message, "Request ID was already used.")
            XCTAssertEqual(
                detail.detail,
                .string("POST /voices/activate"))
            XCTAssertEqual(detail.recoverable, false)
        }
    }

    func testUnknownOperationObjectDetailRoundTrips() async throws {
        let server = try StubServer { _ in
            (404, #"""
            {
              "error": {
                "code": "operation_result_unknown",
                "message": "Operation result is unknown.",
                "detail": {
                  "request_id": "request-1",
                  "phase": "unknown",
                  "retryable": true
                },
                "recoverable": true
              }
            }
            """#)
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil)

        do {
            _ = try await client.operation(requestID: "request-1")
            XCTFail("expected management failure")
        } catch let error as DaemonError {
            guard case .management(let status, let detail) = error else {
                return XCTFail("expected management failure, got \(error)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(detail.code, "operation_result_unknown")
            XCTAssertEqual(detail.message, "Operation result is unknown.")
            XCTAssertEqual(
                detail.detail,
                .object([
                    "request_id": .string("request-1"),
                    "phase": .string("unknown"),
                    "retryable": .bool(true),
                ]))
            XCTAssertEqual(detail.recoverable, true)

            let encoded = try DaemonClient.encoder.encode(detail)
            let decoded = try DaemonClient.decoder.decode(
                ManagementErrorDetail.self,
                from: encoded)
            XCTAssertEqual(decoded, detail)
        }
        XCTAssertEqual(
            server.requests.map(\.path),
            ["/operations/request-1"])
    }

    func testInvalidSuccessBodyHasDedicatedError() async throws {
        let server = try StubServer { _ in (200, #"{"service":"wren"}"#) }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil)
        do {
            _ = try await client.meta()
            XCTFail("expected decoding failure")
        } catch let error as DaemonError {
            guard case .invalidDecoding = error else {
                return XCTFail("expected invalid decoding, got \(error)")
            }
        }
    }

    func testManagementRedirectAwayFromEndpointIsRejected() async {
        let redirected = URL(string: "http://127.0.0.1:9998/meta")!
        let client = DaemonClient(
            host: "127.0.0.1:9999",
            token: nil
        ) { _ in
            let body = Data(#"""
            {
              "service": "wren",
              "protocol_version": 2,
              "instance_id": "redirected",
              "started_at": "2026-08-11T00:00:00Z",
              "capabilities": []
            }
            """#.utf8)
            let response = HTTPURLResponse(
                url: redirected,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (body, response)
        }

        do {
            _ = try await client.meta()
            XCTFail("expected redirected management failure")
        } catch let error as DaemonError {
            guard case .transport(let description) = error else {
                return XCTFail("expected transport failure, got \(error)")
            }
            XCTAssertTrue(description.contains("redirected"))
        } catch {
            XCTFail("expected DaemonError, got \(error)")
        }
    }

    func testInvalidMutationSuccessBodyIsAmbiguous() async throws {
        let server = try StubServer { _ in
            (202, #"{"id":"request-8"}"#)
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil)

        do {
            _ = try await client.activateVoice(
                "wintermute",
                requestID: "request-8")
            XCTFail("expected ambiguous mutation")
        } catch let error as DaemonError {
            guard case .ambiguousSubmittedMutation(
                let requestID,
                _
            ) = error else {
                return XCTFail("expected ambiguity, got \(error)")
            }
            XCTAssertEqual(requestID, "request-8")
        }
    }

    func testRefusalAndAmbiguousMutationAreDistinct() async throws {
        let refused = DaemonClient(
            host: "127.0.0.1:9999",
            token: nil
        ) { _ in
            throw URLError(.cannotConnectToHost)
        }
        do {
            _ = try await refused.meta()
            XCTFail("expected refusal")
        } catch let error as DaemonError {
            guard case .transportRefused(let host) = error else {
                return XCTFail("expected refusal, got \(error)")
            }
            XCTAssertEqual(host, "127.0.0.1:9999")
        }

        let ambiguous = DaemonClient(
            host: "127.0.0.1:9999",
            token: nil
        ) { _ in
            throw URLError(.networkConnectionLost)
        }
        do {
            _ = try await ambiguous.activateVoice(
                "wintermute",
                requestID: "request-7")
            XCTFail("expected ambiguous mutation")
        } catch let error as DaemonError {
            guard case .ambiguousSubmittedMutation(
                let requestID,
                _
            ) = error else {
                return XCTFail("expected ambiguity, got \(error)")
            }
            XCTAssertEqual(requestID, "request-7")
        }
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let stateJSON = #"""
    {
      "revision": 42,
      "voices_revision": 9,
      "lifecycle": {"phase": "ready", "message": null},
      "synthesis": {
        "ready": true,
        "active_voice": "c3po_god",
        "effects": true,
        "default_synthesis_rate": 1.0,
        "backend": "qwentts",
        "model": "qwen"
      },
      "operation": null,
      "playback": {
        "pending": 0,
        "speaking": false,
        "paused": false
      },
      "last_error": null
    }
    """#
}
