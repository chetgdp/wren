import Foundation

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

    struct Progress: Equatable {
        let title: String
        let detail: String
        let fraction: Double?
    }

    struct VoiceChoice: Equatable {
        let id: String
        let title: String
        let isChecked: Bool
        let isEnabled: Bool
    }

    enum OutputTarget: Equatable {
        case systemDefault
        case device(AudioOutputDevice)
        case unavailable(uid: String)
    }

    struct OutputChoice: Equatable {
        let target: OutputTarget
        let title: String
        let isChecked: Bool
        let isEnabled: Bool
    }

    struct Command: Equatable {
        let title: String
        let isEnabled: Bool
    }

    struct Login: Equatable {
        let isVisible: Bool
        let isOn: Bool
        let isEnabled: Bool
        let error: String?
    }

    enum RecoveryKind: Equatable {
        case retryStartup
        case resetInvalidSettings
        case revealLogs(URL)
    }

    struct RecoveryAction: Equatable {
        let kind: RecoveryKind
        let title: String
        let isEnabled: Bool
    }

    let status: Status
    let progress: Progress?
    let statusBarBadge: String?
    let statusItemDimmed: Bool
    let activeVoiceName: String?
    let voiceBadge: String
    let voices: [VoiceChoice]
    let addVoiceVisible: Bool
    let addVoiceEnabled: Bool
    let manageVoicesEnabled: Bool
    let speakingRate: Double
    let speakingRateEnabled: Bool
    let effectsOn: Bool
    let effectsEnabled: Bool
    let outputBadge: String
    let outputChoices: [OutputChoice]
    let outputEnabled: Bool
    let outputMessage: String?
    let pause: Command
    let stop: Command
    let login: Login
    let recoveryActions: [RecoveryAction]

    init(state: AppState) {
        let voiceState = state.voiceManagement
        let activeName = Self.voiceName(
            id: voiceState.activeID,
            profiles: voiceState.profiles
        )
        let operationPending =
            state.daemon?.operation?.phase.isTerminal == false
        let blocked = state.pendingAction != nil || operationPending
        let daemonReady = Self.daemonReady(state)
        let presentation = Self.presentation(
            state: state,
            activeName: activeName,
            profiles: voiceState.profiles
        )

        status = presentation.status
        progress = presentation.progress
        statusBarBadge = presentation.badge
        statusItemDimmed = Self.statusItemIsDimmed(state)
        activeVoiceName = activeName
        voiceBadge = activeName ?? "No Active Voice"
        voices = voiceState.readyProfiles.map { profile in
            VoiceChoice(
                id: profile.id,
                title: profile.displayName,
                isChecked: profile.id == voiceState.activeID,
                isEnabled: daemonReady && !blocked
            )
        }
        addVoiceVisible = voiceState.importAvailable
        addVoiceEnabled = voiceState.importAvailable && !blocked
        manageVoicesEnabled = true
        speakingRate = state.localPlayer.speakingRate
        speakingRateEnabled = true
        effectsOn = state.daemon?.synthesis.effects ?? false
        effectsEnabled = daemonReady && !blocked

        let output = Self.outputPresentation(
            state.audioOutput,
            blocked: blocked
        )
        outputBadge = output.badge
        outputChoices = output.choices
        outputEnabled = output.enabled
        outputMessage = output.message

        let playback = state.daemon?.playback
        let isPaused = state.localPlayer.isPaused
            || playback?.paused == true
        let isActive = isPaused
            || playback?.speaking == true
            || (playback?.pending ?? 0) > 0
        let playbackReady = Self.playbackReady(state)
        pause = Command(
            title: isPaused ? "Resume" : "Pause",
            isEnabled: playbackReady && isActive && !blocked
        )
        stop = Command(
            title: "Stop",
            isEnabled: playbackReady && isActive && !blocked
        )
        login = Login(
            isVisible: state.loginItem.isAvailable,
            isOn: state.loginItem.isEnabled,
            isEnabled: state.loginItem.isAvailable && !blocked,
            error: state.loginItem.error
        )
        recoveryActions = Self.recoveryActions(
            state: state,
            blocked: blocked
        )
    }
}

private extension WrenMenuModel {
    struct Presentation {
        let status: Status
        let progress: Progress?
        let badge: String?
    }

    struct OutputPresentation {
        let badge: String
        let choices: [OutputChoice]
        let enabled: Bool
        let message: String?
    }

    struct Activation {
        let targetName: String
        let phase: OperationPhase
        let fraction: Double?
        let error: String?
    }

    static func presentation(
        state: AppState,
        activeName: String?,
        profiles: [VoiceProfile]
    ) -> Presentation {
        guard let manager = state.manager else {
            return pendingPresentation(
                title: "Starting Wren",
                detail: "Connecting to the speech service",
                progressTitle: "Connecting"
            )
        }

        switch manager.phase {
        case .starting:
            return pendingPresentation(
                title: "Starting Wren",
                detail: "Connecting to the speech service",
                progressTitle: "Connecting"
            )
        case .provisioning(let message):
            return provisioningPresentation(message)
        case .recovering(let attempt, let delay):
            let seconds = String(format: "%.1f", delay)
            return pendingPresentation(
                title: "Reconnecting",
                detail: "Retry \(attempt) in \(seconds) seconds",
                progressTitle: "Reconnecting to Wren"
            )
        case .failed:
            let title = manager.ownership == .connected
                ? "Connection Lost"
                : "Wren Needs Attention"
            let detail = manager.error?.message
                ?? state.actionableError?.message
                ?? "Wren could not start."
            return Presentation(
                status: Status(
                    title: title,
                    detail: detail,
                    tone: .error
                ),
                progress: nil,
                badge: nil
            )
        case .ready:
            break
        }

        guard let daemon = state.daemon else {
            return pendingPresentation(
                title: "Connecting to Wren",
                detail: voiceDetail(activeName),
                progressTitle: "Loading speech service"
            )
        }

        if let activation = activation(
            state: state,
            profiles: profiles
        ) {
            return activationPresentation(
                activation,
                activeName: activeName
            )
        }

        switch daemon.lifecycle.phase {
        case .starting:
            return pendingPresentation(
                title: "Starting Speech",
                detail: voiceDetail(activeName),
                progressTitle: "Starting speech service"
            )
        case .loading:
            return pendingPresentation(
                title: "Loading Voice",
                detail: voiceDetail(activeName),
                progressTitle: "Loading voice"
            )
        case .degraded, .failed:
            let detail = daemon.lastError?.message
                ?? daemon.lifecycle.message
                ?? "Speech is temporarily unavailable."
            return Presentation(
                status: Status(
                    title: "Speech Unavailable",
                    detail: detail,
                    tone: .error
                ),
                progress: nil,
                badge: nil
            )
        case .ready:
            break
        }

        guard daemon.synthesis.ready else {
            return pendingPresentation(
                title: "Loading Voice",
                detail: voiceDetail(activeName),
                progressTitle: "Loading voice"
            )
        }

        if let error = state.actionableError {
            let title = error.recoverable
                ? "Action Didn’t Complete"
                : "Wren Needs Attention"
            return Presentation(
                status: Status(
                    title: title,
                    detail: joinedDetail(
                        error.message,
                        stillUsing(activeName)
                    ),
                    tone: .error
                ),
                progress: nil,
                badge: nil
            )
        }

        let isPaused = state.localPlayer.isPaused
            || daemon.playback.paused
        let title: String
        if isPaused {
            title = "Paused"
        } else if daemon.playback.speaking
            || daemon.playback.pending > 0 {
            title = "Speaking"
        } else if manager.ownership == .connected {
            title = "Connected"
        } else {
            title = "Ready"
        }
        let warning = state.audioOutput.fallbackWarning
        let detail = joinedDetail(
            voiceDetail(activeName),
            warning
        )
        return Presentation(
            status: Status(
                title: title,
                detail: detail,
                tone: warning == nil ? .normal : .warning
            ),
            progress: nil,
            badge: nil
        )
    }

    static func pendingPresentation(
        title: String,
        detail: String,
        progressTitle: String
    ) -> Presentation {
        Presentation(
            status: Status(
                title: title,
                detail: detail,
                tone: .normal
            ),
            progress: Progress(
                title: progressTitle,
                detail: "Please wait…",
                fraction: nil
            ),
            badge: nil
        )
    }

    static func provisioningPresentation(
        _ message: String
    ) -> Presentation {
        let downloading = message.localizedCaseInsensitiveContains(
            "downloading"
        )
        let fraction = downloading ? percentFraction(message) : nil
        let progressTitle = downloading
            ? "Downloading voice resources"
            : "Preparing voice resources"
        let detail: String
        if let fraction {
            detail = percentText(fraction)
        } else if downloading {
            detail = "Download in progress"
        } else {
            detail = "Completing first-time setup"
        }
        return Presentation(
            status: Status(
                title: "Preparing Wren",
                detail: detail,
                tone: .normal
            ),
            progress: Progress(
                title: progressTitle,
                detail: detail,
                fraction: fraction
            ),
            badge: fraction.map(percentText)
        )
    }

    static func activationPresentation(
        _ activation: Activation,
        activeName: String?
    ) -> Presentation {
        if activation.phase == .failed {
            let detail = joinedDetail(
                activation.error ?? "The voice could not be loaded.",
                stillUsing(activeName)
            )
            return Presentation(
                status: Status(
                    title: "Couldn’t switch to "
                        + activation.targetName,
                    detail: detail,
                    tone: .error
                ),
                progress: nil,
                badge: nil
            )
        }

        let stage: String
        if activation.phase == .committing {
            stage = "Loading \(activation.targetName)"
        } else if activation.phase == .preparing,
                  activation.fraction != nil {
            stage = "Downloading \(activation.targetName)"
        } else {
            stage = "Preparing \(activation.targetName)"
        }
        let progressDetail = activation.fraction.map(percentText)
            ?? stillUsing(activeName)
            ?? "Please wait…"
        return Presentation(
            status: Status(
                title: "Switching to \(activation.targetName)",
                detail: stillUsing(activeName)
                    ?? "The new voice is loading.",
                tone: .normal
            ),
            progress: Progress(
                title: stage,
                detail: progressDetail,
                fraction: activation.fraction
            ),
            badge: activation.fraction.map(percentText)
        )
    }

    static func activation(
        state: AppState,
        profiles: [VoiceProfile]
    ) -> Activation? {
        let operation = state.daemon?.operation
        if let operation,
           operation.kind == "activate_voice",
           operation.phase != .succeeded {
            let target = operation.target
                ?? pendingVoiceID(state.pendingAction)
                ?? "voice"
            return Activation(
                targetName: voiceName(
                    id: target,
                    profiles: profiles
                ) ?? target,
                phase: operation.phase,
                fraction: clamped(operation.progress),
                error: operation.error?.message
            )
        }
        guard let target = pendingVoiceID(state.pendingAction) else {
            return nil
        }
        return Activation(
            targetName: voiceName(
                id: target,
                profiles: profiles
            ) ?? target,
            phase: .pending,
            fraction: nil,
            error: nil
        )
    }

    static func pendingVoiceID(
        _ action: PendingAction?
    ) -> String? {
        guard case .activateVoice(let id, _)? = action else {
            return nil
        }
        return id
    }

    static func outputPresentation(
        _ output: AudioOutputState,
        blocked: Bool
    ) -> OutputPresentation {
        let enabled = output.providerError == nil && !blocked
        let effective = output.effectiveDevice?.name
        let badge: String
        if output.fallbackWarning != nil {
            badge = effective.map { "Fallback: \($0)" }
                ?? "Fallback Unavailable"
        } else {
            badge = effective ?? "Unavailable"
        }

        var choices = [OutputChoice(
            target: .systemDefault,
            title: "System Default",
            isChecked: output.desiredUID == nil,
            isEnabled: enabled
        )]
        let devices = output.devices.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
        if let desiredUID = output.desiredUID,
           !devices.contains(where: { $0.uid == desiredUID }) {
            let name = output.desiredName ?? desiredUID
            choices.append(OutputChoice(
                target: .unavailable(uid: desiredUID),
                title: "\(name) (Disconnected)",
                isChecked: true,
                isEnabled: false
            ))
        }
        choices.append(contentsOf: devices.map { device in
            OutputChoice(
                target: .device(device),
                title: device.name,
                isChecked: device.uid == output.desiredUID,
                isEnabled: enabled
            )
        })
        return OutputPresentation(
            badge: badge,
            choices: choices,
            enabled: enabled,
            message: output.fallbackWarning ?? output.providerError
        )
    }

    static func recoveryActions(
        state: AppState,
        blocked: Bool
    ) -> [RecoveryAction] {
        var actions: [RecoveryAction] = []
        let recovery = state.managerRecovery
        if recovery.canRetry {
            actions.append(RecoveryAction(
                kind: .retryStartup,
                title: "Retry Wren",
                isEnabled: !blocked
            ))
        }
        if recovery.canResetInvalidSettings {
            actions.append(RecoveryAction(
                kind: .resetInvalidSettings,
                title: "Reset Invalid Settings…",
                isEnabled: !blocked
            ))
        }
        if state.manager?.ownership == .managed,
           hasServiceError(state),
           let url = recovery.revealLogURL {
            actions.append(RecoveryAction(
                kind: .revealLogs(url),
                title: "Reveal Logs",
                isEnabled: true
            ))
        }
        return actions
    }

    static func hasServiceError(_ state: AppState) -> Bool {
        if state.actionableError != nil {
            return true
        }
        if state.manager?.phase == .failed {
            return true
        }
        guard let phase = state.daemon?.lifecycle.phase else {
            return false
        }
        return phase == .degraded || phase == .failed
    }

    static func daemonReady(_ state: AppState) -> Bool {
        state.manager?.phase == .ready
            && state.daemon?.lifecycle.phase == .ready
            && state.daemon?.synthesis.ready == true
    }

    static func playbackReady(_ state: AppState) -> Bool {
        state.manager?.phase == .ready
            && state.daemon?.lifecycle.phase == .ready
    }

    static func statusItemIsDimmed(_ state: AppState) -> Bool {
        if state.manager?.phase == .failed {
            return true
        }
        guard let phase = state.daemon?.lifecycle.phase else {
            return false
        }
        return phase == .degraded || phase == .failed
    }

    static func voiceName(
        id: String?,
        profiles: [VoiceProfile]
    ) -> String? {
        guard let id else { return nil }
        return profiles.first(where: { $0.id == id })?.displayName
            ?? id
    }

    static func voiceDetail(_ name: String?) -> String {
        name.map { "Voice: \($0)" } ?? "No active voice"
    }

    static func stillUsing(_ name: String?) -> String? {
        name.map { "Still using \($0)" }
    }

    static func joinedDetail(
        _ first: String?,
        _ second: String?
    ) -> String {
        [first, second]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    static func clamped(_ value: Double?) -> Double? {
        value.map { min(1, max(0, $0)) }
    }

    static func percentFraction(_ message: String) -> Double? {
        let numbers = message.split { character in
            !character.isNumber && character != "."
        }
        guard let token = numbers.last,
              let value = Double(String(token))
        else { return nil }
        return min(1, max(0, value / 100))
    }

    static func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
