import Foundation

enum SettingsDestination: CaseIterable, Hashable, Sendable {
    case server
    case voices
    case output
    case about
}

enum SettingsCopy {
    static let appName = "Wren"
    static let windowTitle = "Wren Settings"
    static let sectionPickerLabel = "Settings section"

    enum Server {
        static let title = "Server"
        static let subtitle = "Configure synthesis host, active client, and defaults."
        static let endpointSection = "Endpoint"
        static let host = "Host"
        static let saveHost = "Save Host"
        static let status = "Status"
        static let activeClient = "Active Client"
        static let playHere = "Play Here"
        static let optionsSection = "Audio Options"
        static let effects = "Audio Effects"
        static let effectsDescription = "Toggle server-side audio effects filter chain."
    }

    enum Voices {
        static let title = "Voices"
        static let subtitle = "Select, manage, and clone reference voice profiles."
        static let listSection = "Available Voices"
        static let activeTag = "Active"
        static let useVoice = "Use"
        static let renameVoice = "Rename…"
        static let deleteVoice = "Delete…"
        static let addSection = "Add New Voice"
        static let voiceId = "Voice ID"
        static let voiceIdPlaceholder = "e.g. custom_voice"
        static let displayName = "Display Name"
        static let displayNamePlaceholder = "e.g. Custom Voice"
        static let transcript = "Transcript"
        static let transcriptPlaceholder = "Exact text spoken in audio sample"
        static let audioFile = "Reference Audio"
        static let chooseAudio = "Choose Audio…"
        static let noAudioSelected = "No file selected"
        static let uploadVoice = "Upload Voice"
        static let uploadingVoice = "Uploading…"
    }

    enum Output {
        static let title = "Output"
        static let subtitle = "Route local playback audio to designated device."
        static let deviceSection = "Audio Output Device"
        static let systemDefault = "System Default"
        static let devicePicker = "Device"
    }

    enum About {
        static let title = "About"
        static let subtitle = "Low-latency network speech synthesis client for macOS."
        static let identitySection = "Made for your Mac"
        static let versionPrefix = "Version"
        static let development = "Development"
        static let legalSection = "Legal"
        static let license = "License"
        static let licenseDetail = "Bundled in repository"
    }
}
