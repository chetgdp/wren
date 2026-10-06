import Foundation

/// Pure description of the menu, derived from AppState. The menu bar
/// compares models to decide what to touch, so everything here must be
/// cheap Equatable values.
struct WrenMenuModel: Equatable {
    enum Tone: Equatable {
        case normal
        case warning
        case error
    }

    struct Status: Equatable {
        let title: String
        let detail: String
        let tone: Tone
    }

    struct VoiceChoice: Equatable {
        let id: String
        let title: String
        let isChecked: Bool
    }

    enum OutputTarget: Equatable {
        case systemDefault
        case device(AudioOutputDevice)

        /// Stable identity for in-place updates; a renamed device keeps
        /// its menu item.
        var key: String {
            switch self {
            case .systemDefault: return ""
            case .device(let device): return device.uid
            }
        }
    }

    struct OutputChoice: Equatable {
        let target: OutputTarget
        let title: String
        let isChecked: Bool
    }

    struct Login: Equatable {
        let isOn: Bool
        let isEnabled: Bool
        let error: String?
    }

    /// The parts that require adding or removing menu items. When only
    /// titles, checkmarks, or badges change, items are updated in place;
    /// rebuilding an open menu is what makes rows flicker.
    struct Structure: Equatable {
        let voiceIDs: [String]
        let outputKeys: [String]
    }

    let status: Status
    let clientTitle: String
    let showsPlayHere: Bool
    let voices: [VoiceChoice]
    let voiceBadge: String
    let isConnected: Bool
    let effectsOn: Bool
    let speakingRate: Double
    let outputChoices: [OutputChoice]
    let outputBadge: String
    let isPaused: Bool
    let login: Login

    var structure: Structure {
        Structure(
            voiceIDs: voices.map(\.id),
            outputKeys: outputChoices.map(\.target.key)
        )
    }

    init(state: AppState) {
        isConnected = state.status == .connected
        status = Self.status(state)
        clientTitle = SettingsViewModel.activeClientText(state)
        // Offering "Play here" only makes sense once the server answers.
        showsPlayHere = isConnected && !state.isPlayingHere

        voices = state.voices.map { voice in
            VoiceChoice(
                id: voice.id,
                title: voice.displayName,
                isChecked: voice.id == state.activeVoice
            )
        }
        voiceBadge = voices.first { $0.isChecked }?.title ?? "None"
        effectsOn = state.effects
        speakingRate = state.localPlayer.speakingRate
        isPaused = state.localPlayer.isPaused

        let desired = state.audioOutput.desiredUID
        outputChoices = [
            OutputChoice(
                target: .systemDefault,
                title: "System Default",
                isChecked: desired == nil
            ),
        ] + state.audioOutput.devices.map { device in
            OutputChoice(
                target: .device(device),
                title: device.name,
                isChecked: device.uid == desired
            )
        }
        outputBadge = state.audioOutput.effectiveDevice?.name ?? "Default"

        login = Login(
            isOn: state.loginItem.isEnabled,
            isEnabled: state.loginItem.isAvailable,
            error: state.loginItem.error
        )
    }

    private static func status(_ state: AppState) -> Status {
        switch state.status {
        case .connecting:
            return Status(
                title: "Connecting",
                detail: state.host,
                tone: .warning
            )
        case .connected:
            return Status(
                title: "Connected",
                detail: state.host,
                tone: .normal
            )
        case .unreachable(let message):
            return Status(title: "Unreachable", detail: message, tone: .error)
        }
    }
}
