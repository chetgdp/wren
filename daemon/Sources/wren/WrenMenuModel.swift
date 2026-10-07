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
        let isEnabled: Bool

        init(
            target: OutputTarget,
            title: String,
            isChecked: Bool,
            isEnabled: Bool = true
        ) {
            self.target = target
            self.title = title
            self.isChecked = isChecked
            self.isEnabled = isEnabled
        }
    }

    struct Login: Equatable {
        let isOn: Bool
        let isEnabled: Bool
        let error: String?
    }

    struct LocalServer: Equatable {
        let isOn: Bool
        let isEnabled: Bool
        let detail: String?
        let tone: Tone
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
    let localServer: LocalServer
    var structure: Structure {
        Structure(
            voiceIDs: voices.map(\.id),
            outputKeys: outputChoices.map(\.target.key)
        )
    }

    init(state: AppState) {
        isConnected = state.status == .connected
        status = Self.status(state)
        clientTitle = SettingsModel.activeClientText(state)
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
        let knownUIDs = Set(state.audioOutput.devices.map(\.uid))
        let missingDesired = desired.flatMap { uid in
            knownUIDs.contains(uid) ? nil : uid
        }

        var choices: [OutputChoice] = [
            OutputChoice(
                target: .systemDefault,
                title: "System Default",
                isChecked: desired == nil || missingDesired != nil
            ),
        ]
        choices += state.audioOutput.devices.map { device in
            OutputChoice(
                target: .device(device),
                title: device.name,
                isChecked: device.uid == desired
            )
        }
        if let missingUID = missingDesired {
            let missingName = state.audioOutput.desiredName
                ?? "Missing Device"
            let missingDevice = AudioOutputDevice(
                uid: missingUID,
                name: "\(missingName) (Unavailable)"
            )
            choices.append(OutputChoice(
                target: .device(missingDevice),
                title: "\(missingName) (Unavailable)",
                isChecked: false,
                isEnabled: false
            ))
        }
        outputChoices = choices
        outputBadge = state.audioOutput.effectiveDevice?.name ?? "Default"
        login = Login(
            isOn: state.loginItem.isEnabled,
            isEnabled: state.loginItem.isAvailable,
            error: state.loginItem.error
        )
        localServer = Self.localServer(state)
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
    private static func localServer(_ state: AppState) -> LocalServer {
        let serverState = state.localServer
        let isOn = serverState.isEnabled
        let isLoopback = ServerSupervisor.isLoopbackHost(state.host)

        switch serverState.status {
        case .disabled:
            return LocalServer(
                isOn: false,
                isEnabled: isLoopback,
                detail: nil,
                tone: .normal
            )
        case .unavailable(let reason):
            return LocalServer(
                isOn: isOn,
                isEnabled: isLoopback,
                detail: reason,
                tone: .warning
            )
        case .external:
            return LocalServer(
                isOn: isOn,
                isEnabled: isLoopback,
                detail: "Using existing server",
                tone: .normal
            )
        case .starting:
            return LocalServer(
                isOn: isOn,
                isEnabled: isLoopback,
                detail: "Loading model…",
                tone: .normal
            )
        case .running:
            return LocalServer(
                isOn: isOn,
                isEnabled: isLoopback,
                detail: "Running",
                tone: .normal
            )
        case .crashed(let reason, let retryIn):
            let seconds = Int(retryIn.rounded())
            return LocalServer(
                isOn: isOn,
                isEnabled: isLoopback,
                detail: "Crashed: \(reason), retrying in \(seconds)s",
                tone: .error
            )
        }
    }
}
