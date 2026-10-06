import Foundation

struct SettingsVoiceRow: Equatable, Sendable {
    let id: String
    let displayName: String
    let isActive: Bool

    /// The server refuses to delete the active voice (409 voice_active),
    /// so the button is disabled instead of offering a doomed request.
    var canDelete: Bool { !isActive }
}

struct SettingsOutputOption: Equatable, Sendable {
    let title: String
    let device: AudioOutputDevice?
}

struct SettingsViewModel: Equatable, Sendable {
    let serverHost: String
    let statusText: String
    let activeClientText: String
    let showsPlayHere: Bool
    let voices: [SettingsVoiceRow]
    let outputOptions: [SettingsOutputOption]
    let selectedOutputIndex: Int
    let errorText: String?

    init(state: AppState) {
        serverHost = state.host
        statusText = Self.statusText(state.status)
        activeClientText = Self.activeClientText(state)
        showsPlayHere = !state.isPlayingHere
        voices = state.voices.map { voice in
            SettingsVoiceRow(
                id: voice.id,
                displayName: voice.displayName,
                isActive: voice.id == state.activeVoice
            )
        }
        var options = [
            SettingsOutputOption(title: "System Default", device: nil),
        ]
        options += state.audioOutput.devices.map {
            SettingsOutputOption(title: $0.name, device: $0)
        }
        outputOptions = options
        selectedOutputIndex = options.firstIndex {
            $0.device?.uid == state.audioOutput.desiredUID
        } ?? 0
        errorText = state.lastError
    }

    static func statusText(_ status: ConnectionStatus) -> String {
        switch status {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .unreachable(let message): return "Unreachable: \(message)"
        }
    }

    static func activeClientText(_ state: AppState) -> String {
        if state.isPlayingHere { return "Playing here" }
        guard let client = state.activeClient else {
            return "No Mac is playing"
        }
        return "Playing on \(client.label ?? client.channel)"
    }
}
