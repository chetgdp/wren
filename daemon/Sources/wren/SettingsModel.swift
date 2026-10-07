import Combine
import Foundation

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var selectedDestination: SettingsDestination = .server
    @Published private(set) var state: AppState

    var onUpdateEndpoint: ((String) -> Void)?
    var onClaimActive: (() -> Void)?
    var onActivateVoice: ((String) -> Void)?
    var onRenameVoice: ((String, String) -> Void)?
    var onDeleteVoice: ((String) -> Void)?
    var onAddVoice: ((String, String, URL, String) async -> Bool)?
    var onSetOutputDevice: ((AudioOutputDevice?) -> Void)?
    var onSetEffects: ((Bool) -> Void)?

    init(state: AppState) {
        self.state = state
    }

    func apply(state: AppState) {
        self.state = state
    }

    func selectDestination(_ destination: SettingsDestination) {
        selectedDestination = destination
    }

    func updateEndpoint(host: String) {
        onUpdateEndpoint?(host)
    }

    func claimActive() {
        onClaimActive?()
    }

    func activateVoice(id: String) {
        onActivateVoice?(id)
    }

    func renameVoice(id: String, displayName: String) {
        onRenameVoice?(id, displayName)
    }

    func deleteVoice(id: String) {
        onDeleteVoice?(id)
    }

    func addVoice(
        id: String,
        name: String,
        audioURL: URL,
        transcript: String
    ) async -> Bool {
        if let onAddVoice {
            return await onAddVoice(id, name, audioURL, transcript)
        }
        return false
    }

    func setOutputDevice(_ device: AudioOutputDevice?) {
        onSetOutputDevice?(device)
    }

    func setEffects(_ enabled: Bool) {
        onSetEffects?(enabled)
    }


    // MARK: - Formatters

    nonisolated static func statusText(_ status: ConnectionStatus) -> String {
        switch status {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .unreachable(let message): return "Unreachable: \(message)"
        }
    }

    nonisolated static func activeClientText(_ state: AppState) -> String {
        if state.isPlayingHere { return "Playing here" }
        guard let client = state.activeClient else {
            return "No Mac is playing"
        }
        return "Playing on \(client.label ?? client.channel)"
    }
}
