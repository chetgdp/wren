import Foundation
import XCTest
@testable import wren

final class WrenCLITests: XCTestCase {
    func testVoicesOutputIncludesEveryProfileAndIssue() {
        let response = VoiceListResponse(
            revision: 4,
            voices: [
                VoiceProfile(
                    id: "c3po_god",
                    displayName: "C-3PO",
                    status: .ready,
                    issues: []
                ),
                VoiceProfile(
                    id: "wintermute",
                    displayName: "Wintermute",
                    status: .incomplete,
                    issues: [
                        VoiceIssue(
                            code: "voice_transcript_missing",
                            field: "transcript",
                            message: "Transcript is missing."
                        ),
                    ]
                ),
            ]
        )

        XCTAssertEqual(Voices.output(response), [
            "c3po_god\tC-3PO\tready",
            "wintermute\tWintermute\tincomplete",
            "  transcript: Transcript is missing. "
                + "[voice_transcript_missing]",
        ])
        XCTAssertEqual(
            Voices.output(VoiceListResponse(revision: 5, voices: [])),
            ["no voices"]
        )
    }

    func testStatusOutputNamesEffectiveManagementState() {
        let meta = makeMeta(
            instanceID: "instance-1",
            capabilities: [.stateV2]
        )
        let operation = OperationResponse(
            id: "request-1",
            kind: "activate_voice",
            phase: .preparing,
            target: "wintermute",
            progress: 0.25,
            error: nil,
            response: nil
        )
        var state = makeState(effects: false)
        state.lifecycle = DaemonLifecycle(
            phase: .loading,
            message: "Preparing voice."
        )
        state.operation = operation
        state.playback = PlaybackState(
            pending: 2,
            speaking: true,
            paused: false
        )

        XCTAssertEqual(Status.output(meta: meta, state: state), [
            "service:   wren protocol 2",
            "instance:  instance-1",
            "lifecycle: loading (Preparing voice.)",
            "voice:     wintermute",
            "backend:   qwentts",
            "playback:  speaking=true paused=false pending=2",
            "operation: activate_voice preparing wintermute 25%",
        ])
    }

    func testDoctorReportsAuthoritativeEffectiveAndLocalState() {
        let meta = makeMeta(
            instanceID: "doctor-instance",
            capabilities: [
                .stateV2,
                .voiceList,
                .voiceActivate,
                .settingsV2,
                .segmentPlayer,
            ])
        var state = makeState(effects: true)
        state.synthesis.host = "127.0.0.1"
        state.synthesis.port = 8765
        let voices = VoiceListResponse(
            revision: 9,
            voices: [
                VoiceProfile(
                    id: "wintermute",
                    displayName: "Wintermute",
                    status: .ready,
                    issues: []),
                VoiceProfile(
                    id: "broken",
                    displayName: "Broken",
                    status: .invalid,
                    issues: [
                        VoiceIssue(
                            code: "voice_audio_invalid",
                            field: "audio",
                            message: "Audio is invalid."),
                    ]),
            ])
        let local = DoctorLocalSnapshot(
            settingsPresent: true,
            migrationSourcePresent: true,
            missingAssets: ["qwentts engine"],
            output: "selected Studio Display [display-uid]",
            loginItem: LoginItemState(
                isAvailable: true,
                isEnabled: true,
                error: nil))

        XCTAssertEqual(Doctor.output(
            configuredHost: "127.0.0.1:8765",
            meta: meta,
            state: state,
            voices: voices,
            local: local
        ), [
            "protocol: wren v2 instance=doctor-instance "
                + "capabilities=segment-player,settings-v2,state-v2,"
                + "voice-activate,voice-list",
            "endpoint: configured=127.0.0.1:8765 "
                + "effective=127.0.0.1:8765",
            "state: revision=7 lifecycle=ready",
            "settings: effects=true default_rate=1.0 "
                + "settings.json present; "
                + "legacy migration source retained",
            "voices: revision=9 ready=1 unavailable=1 issues=1 "
                + "active=wintermute",
            "engine: backend=qwentts model=qwen; "
                + "missing local assets: qwentts engine",
            "output: selected Studio Display [display-uid]",
            "login item: enabled",
        ])
    }

    func testDoctorKeepsLocalDiagnosticsDuringEndpointConflict() {
        let local = DoctorLocalSnapshot(
            settingsPresent: true,
            migrationSourcePresent: true,
            missingAssets: ["qwentts engine"],
            output: "system default (Studio Display)",
            loginItem: LoginItemState(
                isAvailable: true,
                isEnabled: false,
                error: nil))

        let lines = Doctor.failureOutput(
            configuredHost: "127.0.0.1:8765",
            error: DaemonError.identity(service: "other"),
            local: local)

        XCTAssertEqual(lines, [
            "protocol: unavailable (endpoint is other, not wren)",
            "endpoint: configured=127.0.0.1:8765 "
                + "conflict or unavailable",
            "state: unavailable",
            "settings: settings.json present; "
                + "legacy migration source retained",
            "voices: unavailable",
            "engine: missing local assets: qwentts engine",
            "output: system default (Studio Display)",
            "login item: disabled",
        ])
    }

    func testDoctorDoesNotInferDisabledFromUnavailableNativeState() {
        let local = DoctorLocalSnapshot(
            settingsPresent: false,
            migrationSourcePresent: false,
            missingAssets: [],
            output: "system default (Studio Display)",
            loginItem: LoginItemState(
                isAvailable: false,
                isEnabled: false,
                error: nil))

        let lines = Doctor.failureOutput(
            configuredHost: "127.0.0.1:8765",
            error: DaemonError.identity(service: "other"),
            local: local)

        XCTAssertEqual(
            lines.last,
            "login item: unavailable (CLI cannot query "
                + "authoritative native-app login state)")
    }

    func testStateJSONIsExactSortedSnakeCase() throws {
        XCTAssertEqual(
            try StateCommand.output(makeState(effects: true)),
            "{\"lifecycle\":{\"phase\":\"ready\"},"
                + "\"playback\":{\"paused\":false,\"pending\":0,"
                + "\"speaking\":false},\"revision\":7,"
                + "\"synthesis\":{\"active_voice\":\"wintermute\","
                + "\"backend\":\"qwentts\","
                + "\"default_synthesis_rate\":1,\"effects\":true,"
                + "\"model\":\"qwen\",\"ready\":true},"
                + "\"voices_revision\":3}"
        )
    }

    func testVoiceUseSendsUUIDKeyAndPollsToSuccess() async throws {
        let requestID = freshRequestID()
        let server = try StubServer { request in
            switch request.path {
            case "/meta":
                return (200, Self.metaJSON(
                    instanceID: "one",
                    capabilities: ["voice-activate"]
                ))
            case "/voices/activate":
                return (202, Self.operationJSON(
                    id: requestID,
                    phase: "pending"
                ))
            case "/operations/\(requestID)":
                return (200, Self.operationJSON(
                    id: requestID,
                    phase: "succeeded",
                    response: #"{"active_voice":"wintermute"}"#
                ))
            default:
                return (404, Self.notFoundJSON)
            }
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: "secret"
        )

        let output = try await VoiceUse.execute(
            client: client,
            voice: "wintermute",
            requestID: requestID,
            delay: { }
        )

        XCTAssertEqual(output, "voice wintermute")
        XCTAssertNotNil(UUID(uuidString: requestID))
        XCTAssertEqual(server.requests.map(\.path), [
            "/meta",
            "/voices/activate",
            "/meta",
            "/operations/\(requestID)",
        ])
        let mutation = try XCTUnwrap(server.requests.dropFirst().first)
        XCTAssertEqual(mutation.method, "POST")
        XCTAssertEqual(
            mutation.headers["idempotency-key"],
            requestID
        )
        XCTAssertEqual(
            String(decoding: mutation.body, as: UTF8.self),
            #"{"voice":"wintermute"}"#
        )
    }


    func testVoiceUseReconcilesAmbiguousSubmission() async throws {
        let requestID = "00000000-0000-4000-8000-000000000099"
        let transport = AmbiguousVoiceTransport(requestID: requestID)
        let client = DaemonClient(
            host: "127.0.0.1:8765",
            token: nil,
            transport: { request in
                try transport.send(request)
            })

        let output = try await VoiceUse.execute(
            client: client,
            voice: "wintermute",
            requestID: requestID,
            delay: { })

        XCTAssertEqual(output, "voice wintermute")
        XCTAssertEqual(transport.paths, [
            "/meta",
            "/voices/activate",
            "/meta",
            "/operations/\(requestID)",
        ])
    }
    func testEffectsSendsOnlyProductSettingAndResolvesResult() async throws {
        let requestID = "00000000-0000-4000-8000-000000000001"
        let server = try StubServer { request in
            switch request.path {
            case "/meta":
                return (200, Self.metaJSON(
                    instanceID: "one",
                    capabilities: ["settings-v2"]
                ))
            case "/settings":
                return (200, Self.stateJSON(effects: true))
            case "/operations/\(requestID)":
                return (500, Self.notFoundJSON)
            default:
                return (404, Self.notFoundJSON)
            }
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil
        )

        let output = try await Effects.execute(
            client: client,
            setting: .on,
            requestID: requestID,
            delay: { }
        )

        XCTAssertEqual(output, "effects on")
        XCTAssertEqual(server.requests.map(\.path), [
            "/meta",
            "/settings",
        ])
        let mutation = server.requests[1]
        XCTAssertEqual(mutation.method, "PATCH")
        XCTAssertEqual(
            mutation.headers["idempotency-key"],
            requestID
        )
        XCTAssertEqual(
            String(decoding: mutation.body, as: UTF8.self),
            #"{"effects":true}"#
        )
    }

    func testStatusReadsMetaThenState() async throws {
        let server = try StubServer { request in
            switch request.path {
            case "/meta":
                return (200, Self.metaJSON(
                    instanceID: "one",
                    capabilities: ["state-v2"]
                ))
            case "/state":
                return (200, Self.stateJSON(effects: false))
            default:
                return (404, Self.notFoundJSON)
            }
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil
        )

        let output = try await Status.execute(client: client)

        XCTAssertEqual(server.requests.map(\.path), ["/meta", "/state"])
        XCTAssertEqual(output[3], "voice:     wintermute")
        XCTAssertEqual(output[4], "backend:   qwentts")
    }

    func testVoiceUseFailsWhenDaemonInstanceChanges() async throws {
        let requestID = "00000000-0000-4000-8000-000000000002"
        let lock = NSLock()
        var metaCalls = 0
        let server = try StubServer { request in
            switch request.path {
            case "/meta":
                let instanceID = lock.withLock { () -> String in
                    metaCalls += 1
                    return metaCalls == 1 ? "old" : "new"
                }
                return (200, Self.metaJSON(
                    instanceID: instanceID,
                    capabilities: ["voice-activate"]
                ))
            case "/voices/activate":
                return (202, Self.operationJSON(
                    id: requestID,
                    phase: "pending"
                ))
            default:
                return (404, Self.notFoundJSON)
            }
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil
        )

        do {
            _ = try await VoiceUse.execute(
                client: client,
                voice: "wintermute",
                requestID: requestID,
                delay: { }
            )
            XCTFail("expected changed-instance failure")
        } catch {
            XCTAssertEqual(
                String(describing: error),
                "daemon instance changed from old to new while operation "
                    + "\(requestID) was running"
            )
        }
        XCTAssertEqual(server.requests.map(\.path), [
            "/meta", "/voices/activate", "/meta",
        ])
    }

    func testVoiceUseSurfacesStructuredOperationFailure() async throws {
        let requestID = "00000000-0000-4000-8000-000000000003"
        let server = try StubServer { request in
            switch request.path {
            case "/meta":
                return (200, Self.metaJSON(
                    instanceID: "one",
                    capabilities: ["voice-activate"]
                ))
            case "/voices/activate":
                return (202, Self.operationJSON(
                    id: requestID,
                    phase: "pending"
                ))
            case "/operations/\(requestID)":
                return (200, Self.failedOperationJSON(id: requestID))
            default:
                return (404, Self.notFoundJSON)
            }
        }
        defer { server.stop() }
        let client = DaemonClient(
            host: "127.0.0.1:\(server.port)",
            token: nil
        )

        do {
            _ = try await VoiceUse.execute(
                client: client,
                voice: "wintermute",
                requestID: requestID,
                delay: { }
            )
            XCTFail("expected structured operation failure")
        } catch {
            XCTAssertEqual(
                String(describing: error),
                "voice_prepare_failed: Could not prepare Wintermute."
            )
        }
    }

    func testFreshMutationRequestIDsAreDistinctUUIDs() {
        let first = freshRequestID()
        let second = freshRequestID()

        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertNotNil(UUID(uuidString: second))
    }

    private func makeMeta(
        instanceID: String,
        capabilities: [DaemonCapability]
    ) -> MetaResponse {
        MetaResponse(
            service: "wren",
            protocolVersion: 2,
            instanceID: instanceID,
            startedAt: "2026-08-11T00:00:00Z",
            capabilities: capabilities
        )
    }

    private func makeState(effects: Bool) -> DaemonStateResponse {
        DaemonStateResponse(
            revision: 7,
            voicesRevision: 3,
            lifecycle: DaemonLifecycle(phase: .ready, message: nil),
            synthesis: SynthesisState(
                ready: true,
                activeVoice: "wintermute",
                effects: effects,
                defaultSynthesisRate: 1,
                backend: "qwentts",
                model: "qwen",
                host: nil,
                port: nil,
                voicesDirectory: nil
            ),
            operation: nil,
            playback: PlaybackState(
                pending: 0,
                speaking: false,
                paused: false
            ),
            lastError: nil
        )
    }

    private static func metaJSON(
        instanceID: String,
        capabilities: [String]
    ) -> String {
        let encoded = capabilities
            .map { "\"\($0)\"" }
            .joined(separator: ",")
        return "{\"service\":\"wren\",\"protocol_version\":2,"
            + "\"instance_id\":\"\(instanceID)\","
            + "\"started_at\":\"2026-08-11T00:00:00Z\","
            + "\"capabilities\":[\(encoded)]}"
    }

    private static func stateJSON(effects: Bool) -> String {
        "{\"revision\":7,\"voices_revision\":3,"
            + "\"lifecycle\":{\"phase\":\"ready\",\"message\":null},"
            + "\"synthesis\":{\"ready\":true,"
            + "\"active_voice\":\"wintermute\","
            + "\"effects\":\(effects),"
            + "\"default_synthesis_rate\":1,"
            + "\"backend\":\"qwentts\",\"model\":\"qwen\","
            + "\"host\":null,\"port\":null,\"voices_dir\":null},"
            + "\"operation\":null,"
            + "\"playback\":{\"pending\":0,\"speaking\":false,"
            + "\"paused\":false},\"last_error\":null}"
    }

    private static func operationJSON(
        id: String,
        phase: String,
        response: String = "null"
    ) -> String {
        "{\"id\":\"\(id)\",\"kind\":\"activate_voice\","
            + "\"phase\":\"\(phase)\",\"target\":\"wintermute\","
            + "\"progress\":null,\"error\":null,"
            + "\"response\":\(response)}"
    }

    private static func failedOperationJSON(id: String) -> String {
        "{\"id\":\"\(id)\",\"kind\":\"activate_voice\","
            + "\"phase\":\"failed\",\"target\":\"wintermute\","
            + "\"progress\":null,\"error\":{"
            + "\"code\":\"voice_prepare_failed\","
            + "\"message\":\"Could not prepare Wintermute.\","
            + "\"detail\":null,\"recoverable\":true},"
            + "\"response\":null}"
    }

    private static let notFoundJSON =
        #"{"error":{"code":"operation_result_unknown","#
        + #""message":"Operation result is unknown.","#
        + #""recoverable":true}}"#
}

private final class AmbiguousVoiceTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let requestID: String
    private var recordedPaths: [String] = []
    private var activationAttempts = 0

    init(requestID: String) {
        self.requestID = requestID
    }

    var paths: [String] {
        lock.withLock { recordedPaths }
    }

    func send(
        _ request: URLRequest
    ) throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        lock.withLock {
            recordedPaths.append(path)
        }
        if path == "/voices/activate" {
            let attempt = lock.withLock { () -> Int in
                activationAttempts += 1
                return activationAttempts
            }
            if attempt == 1 {
                throw URLError(.networkConnectionLost)
            }
        }

        let body: String
        switch path {
        case "/meta":
            body = """
            {"service":"wren","protocol_version":2,
            "instance_id":"one","started_at":"2026-08-11T00:00:00Z",
            "capabilities":["voice-activate"]}
            """
        case "/operations/\(requestID)":
            body = """
            {"id":"\(requestID)","kind":"activate_voice",
            "phase":"succeeded","target":"wintermute",
            "progress":null,"error":null,"response":null}
            """
        default:
            body = "{}"
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
