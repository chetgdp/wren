import Foundation
import XCTest
@testable import wren

final class RequestBuildingTests: XCTestCase {
    let client = DaemonClient(host: "10.0.0.1:8765")

    private func assertBase(
        _ request: URLRequest,
        _ method: String,
        _ path: String,
        json: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(request.httpMethod, method, file: file, line: line)
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://10.0.0.1:8765\(path)",
            file: file,
            line: line
        )
        if json {
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json",
                file: file,
                line: line
            )
        }
    }

    func testGetRoutes() throws {
        assertBase(try client.request(path: "/state"), "GET", "/state",
                   json: false)
        assertBase(try client.request(path: "/voices"), "GET", "/voices",
                   json: false)
        assertBase(try client.request(path: "/health"), "GET", "/health",
                   json: false)
    }

    func testSpeakOmitsChannelWhenNil() throws {
        let request = try client.speakRequest(SpeakRequest(
            text: "hello",
            append: true,
            raw: nil,
            channel: nil
        ))
        assertBase(request, "POST", "/speak")
        let body = jsonBody(request)
        XCTAssertEqual(body["text"] as? String, "hello")
        XCTAssertEqual(body["append"] as? Bool, true)
        XCTAssertNil(body["channel"], "CLI speech must route to active")
        XCTAssertNil(body["raw"])
    }

    func testStopVariants() throws {
        let plain = try client.stopRequest(channel: nil, all: false)
        assertBase(plain, "POST", "/stop")
        XCTAssertTrue(jsonBody(plain).isEmpty)

        let all = try client.stopRequest(channel: nil, all: true)
        XCTAssertEqual(jsonBody(all) as NSDictionary, ["all": true])

        let mine = try client.stopRequest(channel: "mac-a", all: false)
        XCTAssertEqual(jsonBody(mine) as NSDictionary, ["channel": "mac-a"])
    }

    func testPauseAndResume() throws {
        let pause = try client.pauseRequest(true, channel: nil)
        assertBase(pause, "POST", "/pause")
        XCTAssertTrue(jsonBody(pause).isEmpty)
        let resume = try client.pauseRequest(false, channel: "mac-a")
        assertBase(resume, "POST", "/resume")
        XCTAssertEqual(jsonBody(resume) as NSDictionary, ["channel": "mac-a"])
    }

    func testClaimActive() throws {
        let request = try client.claimRequest(channel: "mac-a", label: "a")
        assertBase(request, "POST", "/clients/active")
        XCTAssertEqual(
            jsonBody(request) as NSDictionary,
            ["channel": "mac-a", "label": "a"]
        )
    }

    func testActivateVoiceIsPut() throws {
        let request = try client.activateVoiceRequest("c3po")
        assertBase(request, "PUT", "/voice")
        XCTAssertEqual(jsonBody(request) as NSDictionary, ["voice": "c3po"])
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 180.0)
    }

    func testSettingsUsesSnakeCaseAndOmitsNil() throws {
        let request = try client.settingsRequest(
            SettingsUpdateRequest(effects: true)
        )
        assertBase(request, "PATCH", "/settings")
        XCTAssertEqual(
            jsonBody(request) as NSDictionary,
            ["effects": true]
        )
        let off = try client.settingsRequest(
            SettingsUpdateRequest(effects: false)
        )
        XCTAssertEqual(jsonBody(off) as NSDictionary, ["effects": false])
    }

    func testRenameAndDeleteEncodeIdSegment() throws {
        let rename = try client.renameVoiceRequest(
            id: "my voice/../x",
            displayName: "New"
        )
        XCTAssertEqual(rename.httpMethod, "PATCH")
        XCTAssertEqual(
            rename.url?.absoluteString,
            "http://10.0.0.1:8765/voices/my%20voice%2F..%2Fx"
        )
        XCTAssertEqual(
            jsonBody(rename) as NSDictionary,
            ["display_name": "New"]
        )
        let delete = try client.deleteVoiceRequest(id: "r2")
        assertBase(delete, "DELETE", "/voices/r2", json: false)
        XCTAssertNil(delete.httpBody)
    }

    func testAddVoiceMultipart() throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF])
        let request = try client.addVoiceRequest(
            id: "new",
            name: "New \"Voice\"",
            audio: audio,
            transcript: "line one\nline two",
            boundary: "B"
        )
        assertBase(request, "POST", "/voices", json: false)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=B"
        )
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(
            "name=\"id\"\r\n\r\nnew\r\n"
        ))
        XCTAssertTrue(text.contains(
            "name=\"display_name\"\r\n\r\nNew \"Voice\"\r\n"
        ))
        XCTAssertTrue(text.contains(
            "name=\"transcript\"\r\n\r\nline one\nline two\r\n"
        ))
        XCTAssertTrue(text.contains(
            "name=\"audio\"; filename=\"reference.wav\"\r\n"
                + "Content-Type: audio/wav\r\n\r\n"
        ))
        XCTAssertTrue(body.range(of: audio) != nil, "raw wav bytes kept")
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
    }
}

final class TransportTests: XCTestCase {
    func testErrorEnvelopeSurfacesCode() async {
        let server = FakeServer { _ in
            FakeServer.Reply(
                status: 409,
                json: [
                    "error": [
                        "code": "no_active_client",
                        "message": "No active client",
                    ],
                ]
            )
        }
        let client = DaemonClient(
            host: "h:1",
            transport: server.transport
        )
        do {
            _ = try await client.speak(SpeakRequest(text: "x"))
            XCTFail("expected failure")
        } catch let DaemonError.management(status, detail) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(detail.code, "no_active_client")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testConnectionFailureNamesEndpoint() async {
        let client = DaemonClient(host: "far:9") { _ in
            throw URLError(.cannotConnectToHost)
        }
        do {
            _ = try await client.state()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DaemonError, .notRunning(host: "far:9"))
        }
    }

    func testStateDecodesSnakeCaseIncludingLastSeen() async throws {
        let server = FakeServer { _ in
            FakeServer.Reply(status: 200, json: [
                "ready": true,
                "backend": "qwentts",
                "model": "m",
                "active_voice": "c3po",
                "effects": true,
                "active_client": ["channel": "mac-a_b", "label": "A"],
                "channels": [
                    "mac-a_b": [
                        "label": "A",
                        "speaking": true,
                        "paused": false,
                        "pending": 2,
                        "last_seen": 12.5,
                    ],
                ],
                "voices": [["id": "c3po", "display_name": "C-3PO"]],
            ])
        }
        let client = DaemonClient(
            host: "h:1",
            transport: server.transport
        )
        let state = try await client.state()
        XCTAssertEqual(state.activeVoice, "c3po")
        XCTAssertEqual(state.activeClient?.channel, "mac-a_b")
        // Dictionary keys must survive the snake-case strategy verbatim.
        let channel = try XCTUnwrap(state.channels?["mac-a_b"])
        XCTAssertEqual(channel.pending, 2)
        XCTAssertEqual(channel.lastSeen, 12.5)
        XCTAssertEqual(state.voices?.first?.displayName, "C-3PO")
    }

    /// Real URLSession against a loopback socket: proves the multipart
    /// body survives actual HTTP framing.
    func testAddVoiceRoundTripOverHTTP() async throws {
        let stub = try StubServer { _ in
            (201, #"{"id":"new","display_name":"New"}"#)
        }
        defer { stub.stop() }
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("wren-\(UUID().uuidString).wav")
        try Data("RIFFfakewav".utf8).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let client = DaemonClient(host: "127.0.0.1:\(stub.port)")
        let profile = try await client.addVoice(
            id: "new",
            name: "New",
            audioURL: wav,
            transcript: "hi"
        )
        XCTAssertEqual(profile, VoiceProfile(id: "new", displayName: "New"))
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/voices")
        XCTAssertTrue(
            request.headers["content-type"]?
                .hasPrefix("multipart/form-data; boundary=") ?? false
        )
        XCTAssertNotNil(request.body.range(of: Data("RIFFfakewav".utf8)))
    }
}
