import Foundation

struct SettingsVoiceIssue: Equatable, Sendable {
    let code: String
    let field: String?
    let message: String

    var title: String {
        guard let field, !field.isEmpty else { return message }
        return "\(Self.readable(field)): \(message)"
    }

    var diagnostic: String {
        "Issue code: \(code)"
    }

    private static func readable(_ field: String) -> String {
        field
            .replacingOccurrences(of: "_", with: " ")
            .capitalized(with: Locale(identifier: "en_US_POSIX"))
    }
}

struct SettingsVoiceRow: Equatable, Sendable {
    let id: String
    let displayName: String
    let status: VoiceStatus
    let issues: [SettingsVoiceIssue]
    let isActive: Bool
    let pendingTitle: String?
    let canActivate: Bool
    let canRename: Bool
    let canDelete: Bool

    var statusTitle: String {
        switch status {
        case .ready:
            return "Ready"
        case .incomplete:
            return "Incomplete"
        case .invalid:
            return "Invalid"
        }
    }

    var symbolName: String {
        if isActive { return "checkmark.circle.fill" }
        switch status {
        case .ready:
            return "waveform.circle"
        case .incomplete:
            return "exclamationmark.circle"
        case .invalid:
            return "xmark.circle"
        }
    }
}

enum SettingsVoiceLoadState: Equatable, Sendable {
    case loading
    case empty
    case loaded
}

struct SettingsOutputOption: Equatable, Sendable {
    let title: String
    let device: AudioOutputDevice?
    let isConnected: Bool

    var uid: String? {
        device?.uid
    }
}

struct SettingsOutputViewModel: Equatable, Sendable {
    let options: [SettingsOutputOption]
    let desiredUID: String?
    let desiredTitle: String
    let effectiveTitle: String
    let fallbackWarning: String?
    let providerError: String?
    let selectionEnabled: Bool
}

struct SettingsDiagnosticRow: Equatable, Sendable {
    let label: String
    let value: String
}

struct SettingsDiagnosticsViewModel: Equatable, Sendable {
    let rows: [SettingsDiagnosticRow]
    let errorMessage: String?
}

struct SettingsRecoveryViewModel: Equatable, Sendable {
    let isVisible: Bool
    let message: String?
    let canRetry: Bool
    let canResetInvalidSettings: Bool
    let revealLogURL: URL?
}

struct SettingsViewModel: Equatable, Sendable {
    let voices: [SettingsVoiceRow]
    let voiceLoadState: SettingsVoiceLoadState
    let activeVoiceID: String?
    let pendingVoiceID: String?
    let canAddVoice: Bool
    let addVoiceVisible: Bool
    let libraryNotice: String?
    let voiceError: String?
    let output: SettingsOutputViewModel
    let diagnostics: SettingsDiagnosticsViewModel
    let recovery: SettingsRecoveryViewModel

    init(state: AppState) {
        let management = state.voiceManagement
        let actionPending = state.pendingAction != nil
        let activationAvailable = state.meta?.capabilities
            .contains(.voiceActivate) == true
        let pending = Self.pendingVoice(state.pendingAction)

        voices = management.profiles.map { profile in
            SettingsVoiceRow(
                id: profile.id,
                displayName: profile.displayName,
                status: profile.status,
                issues: profile.issues.map {
                    SettingsVoiceIssue(
                        code: $0.code,
                        field: $0.field,
                        message: $0.message)
                },
                isActive: profile.id == management.activeID,
                pendingTitle: Self.pendingTitle(
                    for: profile.id,
                    mutation: management.pendingMutation),
                canActivate: activationAvailable
                    && profile.status == .ready
                    && profile.id != management.activeID
                    && !actionPending,
                canRename: management.mutationsAvailable
                    && !actionPending,
                canDelete: management.mutationsAvailable
                    && profile.id != management.activeID
                    && !actionPending)
        }
        activeVoiceID = management.activeID
        pendingVoiceID = pending
        addVoiceVisible = management.importAvailable
        canAddVoice = management.importAvailable && !actionPending
        libraryNotice = Self.libraryNotice(management)
        voiceError = management.actionableError?.message
        if state.voices == nil {
            voiceLoadState = .loading
        } else if management.profiles.isEmpty {
            voiceLoadState = .empty
        } else {
            voiceLoadState = .loaded
        }
        output = Self.outputViewModel(state)
        diagnostics = Self.diagnosticsViewModel(state)
        recovery = Self.recoveryViewModel(state)
    }

    func voice(id: String?) -> SettingsVoiceRow? {
        guard let id else { return nil }
        return voices.first { $0.id == id }
    }

    private static func pendingVoice(_ action: PendingAction?) -> String? {
        guard case .activateVoice(let id, _) = action else { return nil }
        return id
    }

    private static func pendingTitle(
        for id: String,
        mutation: VoicePendingMutation?
    ) -> String? {
        switch mutation {
        case .activate(let target, _) where target == id:
            return "Switching…"
        case .importVoice(let target, _, _) where target == id:
            return "Adding…"
        case .rename(let target, _) where target == id:
            return "Renaming…"
        case .delete(let target, _) where target == id:
            return "Deleting…"
        default:
            return nil
        }
    }

    private static func libraryNotice(
        _ management: VoiceManagementState
    ) -> String? {
        if management.provenLocalLibrary == nil {
            return "This app cannot prove access to the daemon's exact "
                + "voice library. Import, rename, and delete are disabled; "
                + "ready voices can still be activated."
        }
        if !management.importAvailable {
            return "This daemon does not support staged local voice import."
        }
        return nil
    }

    private static func outputViewModel(
        _ state: AppState
    ) -> SettingsOutputViewModel {
        let audio = state.audioOutput
        var options = [SettingsOutputOption(
            title: "System Default",
            device: nil,
            isConnected: true)]
        options.append(contentsOf: audio.devices.map {
            SettingsOutputOption(
                title: $0.name,
                device: $0,
                isConnected: true)
        })

        let desiredDevice = audio.desiredUID.flatMap { uid in
            audio.devices.first { $0.uid == uid }
        }
        if let uid = audio.desiredUID, desiredDevice == nil {
            let name = audio.desiredName ?? uid
            let device = AudioOutputDevice(uid: uid, name: name)
            options.append(SettingsOutputOption(
                title: "\(name) (Disconnected)",
                device: device,
                isConnected: false))
        }

        let desiredTitle: String
        if audio.desiredUID == nil {
            desiredTitle = "System Default"
        } else if let desiredDevice {
            desiredTitle = desiredDevice.name
        } else {
            desiredTitle = (audio.desiredName ?? audio.desiredUID)
                .map { "\($0) (Disconnected)" }
                ?? "Disconnected Device"
        }

        let selectionPending: Bool
        if case .setOutputDevice? = state.pendingAction {
            selectionPending = true
        } else {
            selectionPending = false
        }
        return SettingsOutputViewModel(
            options: options,
            desiredUID: audio.desiredUID,
            desiredTitle: desiredTitle,
            effectiveTitle: audio.effectiveDevice?.name
                ?? "No Output Available",
            fallbackWarning: audio.fallbackWarning,
            providerError: audio.providerError,
            selectionEnabled: state.pendingAction == nil
                && !selectionPending)
    }

    private static func diagnosticsViewModel(
        _ state: AppState
    ) -> SettingsDiagnosticsViewModel {
        let manager = state.manager
        let daemon = state.daemon
        let meta = state.meta
        let rows = [
            SettingsDiagnosticRow(
                label: "Connection",
                value: connectionTitle(manager)),
            SettingsDiagnosticRow(
                label: "Ownership",
                value: ownershipTitle(manager?.ownership)),
            SettingsDiagnosticRow(
                label: "Endpoint",
                value: state.endpoint.absoluteString),
            SettingsDiagnosticRow(
                label: "Service",
                value: meta?.service ?? "Unavailable"),
            SettingsDiagnosticRow(
                label: "Protocol",
                value: meta.map { String($0.protocolVersion) }
                    ?? "Unavailable"),
            SettingsDiagnosticRow(
                label: "Backend",
                value: daemon?.synthesis.backend ?? "Unavailable"),
            SettingsDiagnosticRow(
                label: "Model",
                value: daemon?.synthesis.model ?? "Unavailable"),
            SettingsDiagnosticRow(
                label: "Voices Directory",
                value: daemon?.synthesis.voicesDirectory ?? "Unavailable"),
            SettingsDiagnosticRow(
                label: "Logs",
                value: manager?.logLocation?.path ?? "Unavailable")
        ]
        let error = state.actionableError?.message
            ?? manager?.error?.message
            ?? daemon?.lastError?.message
        return SettingsDiagnosticsViewModel(
            rows: rows,
            errorMessage: error)
    }

    private static func recoveryViewModel(
        _ state: AppState
    ) -> SettingsRecoveryViewModel {
        let recovery = state.managerRecovery
        let managerFailed: Bool
        if case .failed? = state.manager?.phase {
            managerFailed = true
        } else {
            managerFailed = false
        }
        let reportedRecoverable =
            state.daemon?.lastError?.recoverable == true
            || state.actionableError?.recoverable == true
        let visible = recovery.canRetry
            || recovery.canResetInvalidSettings
            || managerFailed
            || reportedRecoverable
        let message = state.manager?.error?.message
            ?? state.daemon?.lastError?.message
            ?? state.actionableError?.message
        let revealLogURL = state.manager?.ownership == .managed && visible
            ? recovery.revealLogURL
            : nil
        return SettingsRecoveryViewModel(
            isVisible: visible,
            message: message,
            canRetry: recovery.canRetry,
            canResetInvalidSettings:
                recovery.canResetInvalidSettings,
            revealLogURL: revealLogURL)
    }

    private static func connectionTitle(
        _ manager: DaemonManager.State?
    ) -> String {
        guard let manager else { return "Connecting" }
        switch manager.phase {
        case .starting:
            return "Starting"
        case .provisioning(let message):
            return "Preparing: \(message)"
        case .ready:
            return "Connected"
        case .recovering(let attempt, let delay):
            return String(
                format: "Recovering: attempt %d in %.1f seconds",
                attempt,
                delay)
        case .failed:
            return "Failed"
        }
    }

    private static func ownershipTitle(
        _ ownership: DaemonManager.Ownership?
    ) -> String {
        switch ownership {
        case .managed:
            return "Managed by Wren"
        case .connected:
            return "Connected to another owner"
        case nil:
            return "Not established"
        }
    }
}

struct SettingsVoiceImport: Equatable, Sendable {
    let wav: URL
    let transcript: URL
    let displayName: String
    let id: String
}

enum SettingsVoiceImportValidation: Equatable, Sendable {
    case invalid(String)
    case valid(SettingsVoiceImport)

    var message: String? {
        guard case .invalid(let message) = self else { return nil }
        return message
    }

    var submission: SettingsVoiceImport? {
        guard case .valid(let submission) = self else { return nil }
        return submission
    }
}

struct SettingsVoiceImportDraft: Equatable, Sendable {
    private(set) var wavURL: URL?
    private(set) var transcriptURL: URL?
    private(set) var displayName = ""
    private(set) var id = ""
    private var displayNameWasEdited = false
    private var idWasEdited = false

    mutating func chooseWAV(
        _ url: URL,
        fileExists: (URL) -> Bool
    ) {
        wavURL = url
        if let counterpart = Self.counterpart(
            for: url,
            extensions: ["txt", "TXT"],
            fileExists: fileExists
        ) {
            transcriptURL = counterpart
        }
        applyDefaults(from: url)
    }

    mutating func chooseTranscript(
        _ url: URL,
        fileExists: (URL) -> Bool
    ) {
        transcriptURL = url
        if let counterpart = Self.counterpart(
            for: url,
            extensions: ["wav", "WAV"],
            fileExists: fileExists
        ) {
            wavURL = counterpart
        }
        applyDefaults(from: url)
    }

    mutating func setDisplayName(_ value: String) {
        displayName = value
        displayNameWasEdited = true
    }

    mutating func setID(_ value: String) {
        id = value
        idWasEdited = true
    }

    func validate(
        existingIDs: Set<String>,
        importAvailable: Bool
    ) -> SettingsVoiceImportValidation {
        guard importAvailable else {
            return .invalid(
                "Import requires proven access to this daemon's exact "
                    + "local voice library.")
        }
        guard let wavURL else {
            return .invalid("Choose a reference WAV file.")
        }
        guard let transcriptURL else {
            return .invalid("Choose a transcript file.")
        }
        guard wavURL.pathExtension.lowercased() == "wav" else {
            return .invalid("Reference audio must be a WAV file.")
        }
        guard wavURL != transcriptURL else {
            return .invalid("Audio and transcript must be different files.")
        }
        let name = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128 else {
            return .invalid(
                "Display name must contain 1–128 characters.")
        }
        guard VoiceImportStaging.validateID(id) else {
            return .invalid(
                "Stable ID must use 1–32 lowercase letters, digits, "
                    + "hyphens, or underscores.")
        }
        guard !existingIDs.contains(id) else {
            return .invalid(
                "A voice with this stable ID already exists. "
                    + "Choose a different ID.")
        }
        return .valid(SettingsVoiceImport(
            wav: wavURL,
            transcript: transcriptURL,
            displayName: name,
            id: id))
    }

    private mutating func applyDefaults(from url: URL) {
        let basename = url.deletingPathExtension().lastPathComponent
        if !displayNameWasEdited {
            displayName = Self.displayName(from: basename)
        }
        if !idWasEdited {
            id = Self.stableID(from: basename)
        }
    }

    private static func counterpart(
        for url: URL,
        extensions: [String],
        fileExists: (URL) -> Bool
    ) -> URL? {
        let base = url.deletingPathExtension()
        for pathExtension in extensions {
            let candidate = base.appendingPathExtension(pathExtension)
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    private static func displayName(from basename: String) -> String {
        basename
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .capitalized(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func stableID(from basename: String) -> String {
        let folded = basename.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        var bytes: [UInt8] = []
        var separatorPending = false
        for scalar in folded.lowercased().unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            if isLetter || isDigit {
                if separatorPending, !bytes.isEmpty, bytes.count < 32 {
                    bytes.append(45)
                }
                separatorPending = false
                if bytes.count < 32 {
                    bytes.append(UInt8(value))
                }
            } else {
                separatorPending = true
            }
        }
        while bytes.last == 45 {
            bytes.removeLast()
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

enum SettingsVoiceNameValidation {
    static func normalized(_ value: String) -> String? {
        let name = value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128 else { return nil }
        return name
    }
}
