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
            DaemonClient.resolveToken(
                flag: "abc",
                environment: ["WREN_TOKEN": "xyz"]),
            "abc")
        XCTAssertEqual(
            DaemonClient.resolveToken(
                flag: nil,
                environment: ["WREN_TOKEN": "xyz"]),
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
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://127.0.0.1:9999/health")
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

    func testSpeakInputJoinsArguments() throws {
        // Loose words and fish command substitutions (which split output
        // into one argument per line) both land as several arguments.
        XCTAssertEqual(
            try SpeakInput.resolve(arguments: ["googa", "booga", "dogga"]),
            "googa booga dogga")
    }

    func testSpeakInputFallsBackToPipedStdin() throws {
        XCTAssertEqual(
            try SpeakInput.resolve(
                arguments: [], stdinIsTTY: false,
                readStdin: { Data("  from a pipe\n".utf8) }),
            "from a pipe")
    }

    func testSpeakInputRejectsEmpty() {
        // A bare `wren say` on a TTY must error out, not hang reading the
        // keyboard; an empty pipe has nothing to say either.
        XCTAssertThrowsError(
            try SpeakInput.resolve(arguments: [], stdinIsTTY: true,
                                   readStdin: { Data() }))
        XCTAssertThrowsError(
            try SpeakInput.resolve(arguments: [], stdinIsTTY: false,
                                   readStdin: { Data("\n".utf8) }))
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
        let fullBody = try json(client.postRequest(
            path: "/speak",
            body: full.body))
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


    func testHealthDecodesSnakeCasePayload() throws {
        let payload = Data("""
        {"ok": true, "ready": true, "model": "m", "playback": "local",
         "pending": 2, "speaking": true, "paused": false,
         "block": [1, 3], "speed": 1.5}
        """.utf8)
        let health = try DaemonClient.decoder.decode(
            HealthResponse.self,
            from: payload)
        XCTAssertTrue(health.ready)
        XCTAssertEqual(health.pending, 2)
        XCTAssertEqual(health.block, [1, 3])
        XCTAssertEqual(health.speed, 1.5)
    }

}

final class ManagementRequestBuildingTests: XCTestCase {
    private let client = DaemonClient(
        host: "127.0.0.1:9999",
        token: "secret")

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testNativeManagementRequestUsesBearerWithoutOrigin() throws {
        let request = try client.request(path: "/meta")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
    }

    func testPostMutationRequiresIDAndBuildsActivation() throws {
        XCTAssertThrowsError(
            try client.mutationRequest(
                method: "POST",
                path: "/voices/activate",
                requestID: " ",
                body: ActivateVoiceRequest(voice: "wintermute")))

        let request = try client.mutationRequest(
            method: "POST",
            path: "/voices/activate",
            requestID: "request-1",
            body: ActivateVoiceRequest(voice: "wintermute"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/voices/activate")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            "request-1")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json")
        XCTAssertEqual(
            try json(request)["voice"] as? String,
            "wintermute")
    }

    func testPatchAndDeleteMutationRequests() throws {
        let patch = try client.mutationRequest(
            method: "PATCH",
            path: "/voices/wintermute",
            requestID: "request-2",
            body: UpdateVoiceRequest(displayName: "Wintermute"))
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertEqual(patch.url?.path, "/voices/wintermute")
        XCTAssertEqual(
            try json(patch)["display_name"] as? String,
            "Wintermute")

        let delete = try client.mutationRequest(
            method: "DELETE",
            path: "/voices/wintermute",
            requestID: "request-3")
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertEqual(
            delete.value(forHTTPHeaderField: "Idempotency-Key"),
            "request-3")
        XCTAssertNil(delete.httpBody)
        XCTAssertNil(
            delete.value(forHTTPHeaderField: "Content-Type"))
    }

    func testImportAndSettingsBodiesUseSnakeCase() throws {
        let imported = try client.mutationRequest(
            method: "POST",
            path: "/voices/import",
            requestID: "request-4",
            body: ImportVoiceRequest(
                stagingID: "stage-1",
                id: "new_voice",
                displayName: "New Voice"))
        let importBody = try json(imported)
        XCTAssertEqual(importBody["staging_id"] as? String, "stage-1")
        XCTAssertEqual(importBody["id"] as? String, "new_voice")
        XCTAssertEqual(
            importBody["display_name"] as? String,
            "New Voice")

        let settings = try client.mutationRequest(
            method: "PATCH",
            path: "/settings",
            requestID: "request-5",
            body: SettingsUpdateRequest(
                effects: true,
                defaultSynthesisRate: nil))
        let settingsBody = try json(settings)
        XCTAssertEqual(settingsBody["effects"] as? Bool, true)
        XCTAssertNil(settingsBody["default_synthesis_rate"])
    }

    func testIdentityAndCompatibilityAreDistinct() throws {
        let capabilities: [DaemonCapability] = [
            .stateV2,
            .voiceList,
        ]
        let wrongService = MetaResponse(
            service: "other",
            protocolVersion: 2,
            instanceID: "instance",
            startedAt: "now",
            capabilities: capabilities)
        XCTAssertThrowsError(
            try DaemonClient.validateIdentity(wrongService)
        ) { error in
            guard case DaemonError.identity(let service) = error else {
                return XCTFail("expected identity error, got \(error)")
            }
            XCTAssertEqual(service, "other")
        }

        let emptyInstance = MetaResponse(
            service: "wren",
            protocolVersion: 2,
            instanceID: " ",
            startedAt: "now",
            capabilities: capabilities)
        XCTAssertThrowsError(
            try DaemonClient.validateIdentity(emptyInstance)
        ) { error in
            guard case DaemonError.identityMetadata(
                let description
            ) = error else {
                return XCTFail(
                    "expected identity metadata error, got \(error)")
            }
            XCTAssertTrue(description.contains("instance_id"))
        }

        let incompatible = MetaResponse(
            service: "wren",
            protocolVersion: 1,
            instanceID: "instance",
            startedAt: "now",
            capabilities: capabilities)
        XCTAssertThrowsError(
            try DaemonClient.validateIdentity(
                incompatible,
                requiredCapabilities: [.voiceActivate])
        ) { error in
            guard case DaemonError.compatibility(
                let version,
                let missing
            ) = error else {
                return XCTFail("expected compatibility error, got \(error)")
            }
            XCTAssertEqual(version, 1)
            XCTAssertEqual(missing, [.voiceActivate])
        }
    }
}

final class ManagementModelDecodingTests: XCTestCase {
    func testMetaDecodesKnownAndUnknownCapabilities() throws {
        let data = Data(#"""
        {
          "service": "wren",
          "protocol_version": 2,
          "instance_id": "instance-1",
          "started_at": "2026-08-07T01:00:00Z",
          "capabilities": ["state-v2", "future-capability"]
        }
        """#.utf8)
        let meta = try DaemonClient.decoder.decode(
            MetaResponse.self,
            from: data)
        XCTAssertEqual(meta.instanceID, "instance-1")
        XCTAssertEqual(
            meta.capabilities,
            [.stateV2, DaemonCapability(rawValue: "future-capability")])
    }

    func testStableLifecycleOperationAndVoiceValuesDecode() throws {
        let lifecycle = try DaemonClient.decoder.decode(
            [DaemonLifecyclePhase].self,
            from: Data(#"""
            ["starting","loading","ready","degraded","failed"]
            """#.utf8))
        XCTAssertEqual(
            lifecycle,
            [.starting, .loading, .ready, .degraded, .failed])

        let operations = try DaemonClient.decoder.decode(
            [OperationPhase].self,
            from: Data(#"""
            ["pending","preparing","committing","succeeded","failed"]
            """#.utf8))
        XCTAssertEqual(
            operations,
            [.pending, .preparing, .committing, .succeeded, .failed])

        let voices = try DaemonClient.decoder.decode(
            [VoiceStatus].self,
            from: Data(#"""
            ["ready","incomplete","invalid"]
            """#.utf8))
        XCTAssertEqual(voices, [.ready, .incomplete, .invalid])
    }

    func testStateDecodesNullableOptionalFields() throws {
        let data = Data(#"""
        {
          "revision": 42,
          "voices_revision": 9,
          "lifecycle": {"phase": "loading"},
          "synthesis": {
            "ready": false,
            "active_voice": null,
            "effects": true,
            "default_synthesis_rate": 1.0,
            "backend": "qwentts",
            "model": "qwen",
            "host": "127.0.0.1",
            "port": 8765,
            "voices_dir": "/Library/Application Support/Wren/voices"
          },
          "operation": null,
          "playback": {
            "pending": 0,
            "speaking": false,
            "paused": false
          },
          "last_error": null
        }
        """#.utf8)
        let state = try DaemonClient.decoder.decode(
            DaemonStateResponse.self,
            from: data)
        XCTAssertEqual(state.revision, 42)
        XCTAssertEqual(state.voicesRevision, 9)
        XCTAssertEqual(state.lifecycle.phase, .loading)
        XCTAssertNil(state.lifecycle.message)
        XCTAssertNil(state.synthesis.activeVoice)
        XCTAssertEqual(state.synthesis.host, "127.0.0.1")
        XCTAssertEqual(state.synthesis.port, 8765)
        XCTAssertEqual(
            state.synthesis.voicesDirectory,
            "/Library/Application Support/Wren/voices")
        XCTAssertNil(state.operation)
        XCTAssertNil(state.lastError)
    }

    func testSynthesisDiagnosticFieldsRemainOptional() throws {
        let data = Data(#"""
        {
          "ready": true,
          "active_voice": "c3po_god",
          "effects": false,
          "default_synthesis_rate": 1.0,
          "backend": "qwentts",
          "model": "qwen"
        }
        """#.utf8)
        let synthesis = try DaemonClient.decoder.decode(
            SynthesisState.self,
            from: data)
        XCTAssertNil(synthesis.host)
        XCTAssertNil(synthesis.port)
        XCTAssertNil(synthesis.voicesDirectory)
    }

    func testOperationDecodesOptionalResultAndErrorFields() throws {
        let activeData = Data(#"""
        {
          "id": "request-1",
          "kind": "activate_voice",
          "phase": "preparing"
        }
        """#.utf8)
        let active = try DaemonClient.decoder.decode(
            OperationResponse.self,
            from: activeData)
        XCTAssertNil(active.target)
        XCTAssertNil(active.progress)
        XCTAssertNil(active.error)
        XCTAssertNil(active.response)
        XCTAssertFalse(active.phase.isTerminal)

        let completedData = Data(#"""
        {
          "id": "request-1",
          "kind": "activate_voice",
          "phase": "succeeded",
          "target": "wintermute",
          "progress": 1,
          "response": {
            "revision": 43,
            "active_voice": "wintermute"
          }
        }
        """#.utf8)
        let completed = try DaemonClient.decoder.decode(
            OperationResponse.self,
            from: completedData)
        XCTAssertTrue(completed.phase.isTerminal)
        guard case .object(let response)? = completed.response else {
            return XCTFail("expected an operation result object")
        }
        XCTAssertEqual(response["revision"], .number(43))
        XCTAssertEqual(
            response["active_voice"],
            .string("wintermute"))
    }

    func testVoiceListAndIssueDecodeWithoutOptionalField() throws {
        let data = Data(#"""
        {
          "revision": 9,
          "voices": [
            {
              "id": "c3po_god",
              "display_name": "C-3PO",
              "status": "ready",
              "issues": []
            },
            {
              "id": "wintermute",
              "display_name": "Wintermute",
              "status": "incomplete",
              "issues": [{
                "code": "voice_transcript_missing",
                "message": "Transcript required."
              }]
            }
          ]
        }
        """#.utf8)
        let list = try DaemonClient.decoder.decode(
            VoiceListResponse.self,
            from: data)
        XCTAssertEqual(list.revision, 9)
        XCTAssertEqual(list.voices[0].status, .ready)
        XCTAssertNil(list.voices[1].issues[0].field)
    }

    func testStructuredErrorDecodesOptionalMetadata() throws {
        let minimal = Data(#"""
        {
          "error": {
            "code": "busy",
            "message": "Another operation is active."
          }
        }
        """#.utf8)
        let envelope = try DaemonClient.decoder.decode(
            ManagementErrorEnvelope.self,
            from: minimal)
        XCTAssertEqual(envelope.error.code, "busy")
        XCTAssertNil(envelope.error.detail)
        XCTAssertNil(envelope.error.recoverable)

        let complete = Data(#"""
        {
          "error": {
            "code": "voice_transcript_missing",
            "message": "Transcript required.",
            "detail": "profiles/wintermute/transcript.txt",
            "recoverable": true
          }
        }
        """#.utf8)
        let detailed = try DaemonClient.decoder.decode(
            ManagementErrorEnvelope.self,
            from: complete)
        XCTAssertEqual(
            detailed.error.detail,
            .string("profiles/wintermute/transcript.txt"))
        XCTAssertEqual(detailed.error.recoverable, true)
    }

    func testStructuredErrorPreservesEveryJSONDetailShape() throws {
        let data = Data(#"""
        [
          {"code": "object", "message": "object",
           "detail": {"request_id": "request-1", "attempts": 2}},
          {"code": "array", "message": "array",
           "detail": ["request-1", false]},
          {"code": "scalar", "message": "scalar", "detail": 7},
          {"code": "null", "message": "null", "detail": null}
        ]
        """#.utf8)
        let errors = try DaemonClient.decoder.decode(
            [ManagementErrorDetail].self,
            from: data)

        XCTAssertEqual(
            errors.map(\.detail),
            [
                .object([
                    "request_id": .string("request-1"),
                    "attempts": .number(2),
                ]),
                .array([.string("request-1"), .bool(false)]),
                .number(7),
                .null,
            ])
    }
}
