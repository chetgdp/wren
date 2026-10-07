import CoreAudio
import Foundation
@testable import wren

/// Records requests and answers from a routing closure, standing in for
/// the network so DaemonClient and WrenStore run their real code paths.
final class FakeServer: @unchecked Sendable {
    struct Reply {
        var status: Int
        var json: Any
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var route: (URLRequest) -> Reply

    init(route: @escaping (URLRequest) -> Reply = { _ in
        Reply(status: 404, json: [:])
    }) {
        self.route = route
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(_ method: String, _ path: String) -> [URLRequest] {
        requests.filter {
            $0.httpMethod == method && $0.url?.path == path
        }
    }

    var transport: DaemonClient.Transport {
        { [self] request in
            // Serialized so route closures over shared models need no
            // locking of their own.
            let reply = lock.withLock {
                recorded.append(request)
                return route(request)
            }
            let data = try JSONSerialization.data(
                withJSONObject: reply.json,
                options: [.fragmentsAllowed]
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (data, response)
        }
    }
}

func jsonBody(_ request: URLRequest) -> [String: Any] {
    guard let body = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: body)
    else { return [:] }
    return object as? [String: Any] ?? [:]
}

/// A small in-memory server modelled on the contract, for store flows.
final class ContractModel: @unchecked Sendable {
    var activeVoice: String? = "c3po"
    var voices: [[String: Any]] = [
        ["id": "c3po", "display_name": "C-3PO"],
        ["id": "r2", "display_name": "R2"],
    ]
    var effects = false
    var activeClient: [String: Any]?

    func state() -> [String: Any] {
        [
            "ready": true,
            "backend": "qwentts",
            "model": "test",
            "active_voice": activeVoice ?? NSNull(),
            "effects": effects,
            "active_client": activeClient ?? NSNull(),
            "channels": [:] as [String: Any],
            "voices": voices,
        ]
    }

    func handle(_ request: URLRequest) -> FakeServer.Reply {
        let path = request.url?.path ?? ""
        let body = jsonBody(request)
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/state"):
            return FakeServer.Reply(status: 200, json: state())
        case ("POST", "/clients/active"):
            activeClient = [
                "channel": body["channel"] ?? "",
                "label": body["label"] ?? NSNull(),
            ]
            return FakeServer.Reply(
                status: 200,
                json: ["active": body["channel"] ?? ""]
            )
        case ("PUT", "/voice"):
            let id = body["voice"] as? String ?? ""
            guard voices.contains(where: { $0["id"] as? String == id }) else {
                return error(404, "unknown_voice", "no \(id)")
            }
            activeVoice = id
            return FakeServer.Reply(status: 200, json: state())
        case ("PATCH", "/settings"):
            if let value = body["effects"] as? Bool { effects = value }
            return FakeServer.Reply(status: 200, json: state())
        case ("POST", "/voices"):
            let id = "added"
            voices.append(["id": id, "display_name": "Added"])
            return FakeServer.Reply(
                status: 201,
                json: ["id": id, "display_name": "Added"]
            )
        case ("POST", "/stop"), ("DELETE", _):
            return FakeServer.Reply(status: 200, json: ["ok": true])
        case ("POST", "/pause"):
            return FakeServer.Reply(
                status: 200,
                json: ["ok": true, "paused": true]
            )
        case ("POST", "/resume"):
            return FakeServer.Reply(
                status: 200,
                json: ["ok": true, "paused": false]
            )
        default:
            return error(404, "not_found", path)
        }
    }

    private func error(
        _ status: Int,
        _ code: String,
        _ message: String
    ) -> FakeServer.Reply {
        FakeServer.Reply(
            status: status,
            json: ["error": ["code": code, "message": message]]
        )
    }
}

final class MemoryEndpointStore: EndpointPersisting {
    var savedHost: String?

    init(host: String? = nil) {
        savedHost = host
    }
}

final class FakeAudioProvider: AudioOutputDeviceProviding {
    var devices: [AudioOutputDevice] = [
        AudioOutputDevice(uid: "speakers", name: "Speakers"),
    ]

    func snapshot() throws -> AudioOutputDeviceSnapshot {
        AudioOutputDeviceSnapshot(
            devices: devices,
            defaultDevice: ResolvedAudioOutputDevice(
                device: devices[0],
                objectID: 1
            )
        )
    }

    func resolve(uid: String) throws -> ResolvedAudioOutputDevice? {
        devices.firstIndex { $0.uid == uid }.map {
            ResolvedAudioOutputDevice(
                device: devices[$0],
                objectID: AudioDeviceID($0 + 1)
            )
        }
    }

    func startObserving(
        _ handler: @escaping @Sendable (AudioOutputDeviceChange) -> Void
    ) throws {}

    func stopObserving() {}
}

final class FakeLoginItem: LoginItemProviding {
    var enabled = false

    func refresh() -> LoginItemState {
        LoginItemState(isAvailable: true, isEnabled: enabled, error: nil)
    }

    func setEnabled(_ enabled: Bool) -> LoginItemState {
        self.enabled = enabled
        return refresh()
    }
}

func makeState(
    status: ConnectionStatus = .connected,
    voices: [VoiceProfile] = [
        VoiceProfile(id: "c3po", displayName: "C-3PO"),
        VoiceProfile(id: "r2", displayName: "R2"),
    ],
    activeVoice: String? = "c3po",
    activeClient: ClientInfo? = ClientInfo(
        channel: "mac-here",
        label: "here"
    ),
    effects: Bool = false,
    devices: [AudioOutputDevice] = [],
    desiredUID: String? = nil,
    localServer: LocalServerState = LocalServerState(
        isEnabled: true,
        status: .disabled
    )
) -> AppState {
    AppState(
        host: "server:8765",
        status: status,
        channel: "mac-here",
        voices: voices,
        activeVoice: activeVoice,
        activeClient: activeClient,
        effects: effects,
        localPlayer: LocalPlayerState(speakingRate: 1.0, isPaused: false),
        audioOutput: AudioOutputState(
            devices: devices,
            desiredUID: desiredUID,
            desiredName: nil,
            effectiveDevice: devices.first { $0.uid == desiredUID },
            providerError: nil
        ),
        loginItem: LoginItemState(
            isAvailable: true,
            isEnabled: false,
            error: nil
        ),
        localServer: localServer
    )
}
