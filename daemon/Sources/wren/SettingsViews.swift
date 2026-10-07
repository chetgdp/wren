import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                .background.secondary,
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(SettingsCopy.appName)
                    .font(.headline)
                    .fixedSize()
                destinationPicker
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            destinationHeader
            destinationView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var destinationPicker: some View {
        Picker(
            SettingsCopy.sectionPickerLabel,
            selection: Binding(
                get: { model.selectedDestination },
                set: { model.selectDestination($0) }
            )
        ) {
            Label(SettingsCopy.Server.title, systemImage: "server.rack")
                .tag(SettingsDestination.server)
            Label(SettingsCopy.Voices.title, systemImage: "person.wave.2")
                .tag(SettingsDestination.voices)
            Label(SettingsCopy.Output.title, systemImage: "speaker.wave.2")
                .tag(SettingsDestination.output)
            Label(SettingsCopy.About.title, systemImage: "info.circle")
                .tag(SettingsDestination.about)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var destinationHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(destinationTitle)
                .font(.title2.weight(.bold))
            Text(destinationSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private var destinationTitle: String {
        switch model.selectedDestination {
        case .server: return SettingsCopy.Server.title
        case .voices: return SettingsCopy.Voices.title
        case .output: return SettingsCopy.Output.title
        case .about: return SettingsCopy.About.title
        }
    }

    private var destinationSubtitle: String {
        switch model.selectedDestination {
        case .server: return SettingsCopy.Server.subtitle
        case .voices: return SettingsCopy.Voices.subtitle
        case .output: return SettingsCopy.Output.subtitle
        case .about: return SettingsCopy.About.subtitle
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.selectedDestination {
        case .server:
            ServerSettingsView(model: model)
        case .voices:
            VoicesSettingsView(model: model)
        case .output:
            OutputSettingsView(model: model)
        case .about:
            AboutSettingsView()
        }
    }
}

struct ServerSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var hostInput = ""

    var body: some View {
        SettingsPage {
            SettingsSection(title: SettingsCopy.Server.endpointSection) {
                HStack {
                    TextField(
                        SettingsCopy.Server.host,
                        text: $hostInput,
                        prompt: Text(Endpoint.defaultHost)
                    )
                    .textFieldStyle(.roundedBorder)

                    Button(SettingsCopy.Server.saveHost) {
                        model.updateEndpoint(host: hostInput)
                    }
                }

                HStack {
                    Text("\(SettingsCopy.Server.status):")
                        .foregroundStyle(.secondary)
                    Text(SettingsModel.statusText(model.state.status))
                        .fontWeight(.medium)
                }

                HStack {
                    Text("\(SettingsCopy.Server.activeClient):")
                        .foregroundStyle(.secondary)
                    Text(SettingsModel.activeClientText(model.state))
                    Spacer()
                    if !model.state.isPlayingHere {
                        Button(SettingsCopy.Server.playHere) {
                            model.claimActive()
                        }
                    }
                }

                if let error = model.state.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            SettingsSection(title: SettingsCopy.Server.optionsSection) {
                Toggle(isOn: Binding(
                    get: { model.state.effects },
                    set: { model.setEffects($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SettingsCopy.Server.effects)
                        Text(SettingsCopy.Server.effectsDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            }
        }
        .onAppear {
            hostInput = model.state.host
        }
    }
}

struct VoicesSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var voiceIdInput = ""
    @State private var displayNameInput = ""
    @State private var transcriptInput = ""
    @State private var selectedAudioURL: URL?
    @State private var isUploading = false
    @State private var renamingVoice: VoiceProfile?
    @State private var renameInput = ""

    var body: some View {
        SettingsPage {
            SettingsSection(title: SettingsCopy.Voices.listSection) {
                if model.state.voices.isEmpty {
                    Text("No voice profiles loaded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.state.voices, id: \.id) { voice in
                        voiceRow(voice)
                    }
                }
            }

            SettingsSection(title: SettingsCopy.Voices.addSection) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        SettingsCopy.Voices.voiceId,
                        text: $voiceIdInput,
                        prompt: Text(SettingsCopy.Voices.voiceIdPlaceholder)
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        SettingsCopy.Voices.displayName,
                        text: $displayNameInput,
                        prompt: Text(SettingsCopy.Voices.displayNamePlaceholder)
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        SettingsCopy.Voices.transcript,
                        text: $transcriptInput,
                        prompt: Text(SettingsCopy.Voices.transcriptPlaceholder),
                        axis: .vertical
                    )
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)

                    HStack {
                        Button(SettingsCopy.Voices.chooseAudio) {
                            chooseAudioFile()
                        }
                        Text(selectedAudioURL?.lastPathComponent
                            ?? SettingsCopy.Voices.noAudioSelected)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }

                    Button(
                        isUploading
                            ? SettingsCopy.Voices.uploadingVoice
                            : SettingsCopy.Voices.uploadVoice
                    ) {
                        submitVoice()
                    }
                    .disabled(
                        isUploading
                            || voiceIdInput.trimmingCharacters(in: .whitespaces).isEmpty
                            || displayNameInput.trimmingCharacters(in: .whitespaces).isEmpty
                            || transcriptInput.trimmingCharacters(in: .whitespaces).isEmpty
                            || selectedAudioURL == nil
                    )
                }
            }
        }
        .sheet(item: $renamingVoice) { voice in
            renameSheet(for: voice)
        }
    }

    private func voiceRow(_ voice: VoiceProfile) -> some View {
        let isActive = voice.id == model.state.activeVoice
        return HStack {
            Button {
                if !isActive {
                    model.activateVoice(id: voice.id)
                }
            } label: {
                HStack {
                    Text(voice.displayName)
                        .fontWeight(isActive ? .bold : .regular)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isActive {
                Text(SettingsCopy.Voices.activeTag)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            } else {
                Button(SettingsCopy.Voices.useVoice) {
                    model.activateVoice(id: voice.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(SettingsCopy.Voices.renameVoice) {
                renameInput = voice.displayName
                renamingVoice = voice
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(SettingsCopy.Voices.deleteVoice) {
                model.deleteVoice(id: voice.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isActive)
        }
        .padding(.vertical, 4)
    }

    private func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType.wav,
            UTType.audio,
        ]
        if panel.runModal() == .OK {
            selectedAudioURL = panel.url
        }
    }

    private func submitVoice() {
        guard let url = selectedAudioURL else { return }
        let id = voiceIdInput.trimmingCharacters(in: .whitespaces)
        let name = displayNameInput.trimmingCharacters(in: .whitespaces)
        let transcript = transcriptInput.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, !transcript.isEmpty else { return }

        isUploading = true
        Task {
            let ok = await model.addVoice(
                id: id,
                name: name,
                audioURL: url,
                transcript: transcript
            )
            isUploading = false
            if ok {
                voiceIdInput = ""
                displayNameInput = ""
                transcriptInput = ""
                selectedAudioURL = nil
            }
        }
    }

    private func renameSheet(for voice: VoiceProfile) -> some View {
        VStack(spacing: 16) {
            Text("Rename \(voice.displayName)")
                .font(.headline)
            TextField("Display Name", text: $renameInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    renamingVoice = nil
                }
                Spacer()
                Button("Rename") {
                    model.renameVoice(id: voice.id, displayName: renameInput)
                    renamingVoice = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

extension VoiceProfile: Identifiable {}

struct OutputSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage {
            SettingsSection(title: SettingsCopy.Output.deviceSection) {
                HStack {
                    Text(SettingsCopy.Output.devicePicker)
                    Spacer()
                    Picker(
                        SettingsCopy.Output.devicePicker,
                        selection: Binding(
                            get: { model.state.audioOutput.desiredUID },
                            set: { uid in
                                let chosen = model.state.audioOutput.devices
                                    .first { $0.uid == uid }
                                model.setOutputDevice(chosen)
                            }
                        )
                    ) {
                        Text(SettingsCopy.Output.systemDefault)
                            .tag(nil as String?)
                        ForEach(model.state.audioOutput.devices, id: \.uid) { dev in
                            Text(dev.name)
                                .tag(dev.uid as String?)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }
}

struct AboutSettingsView: View {
    private static let appName = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleDisplayName"
    ) as? String
        ?? Bundle.main.object(
            forInfoDictionaryKey: "CFBundleName"
        ) as? String
        ?? SettingsCopy.appName

    private static let version = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String
        ?? SettingsCopy.About.development

    var body: some View {
        SettingsPage {
            SettingsSection(title: SettingsCopy.About.identitySection) {
                HStack(spacing: 16) {
                    Image(systemName: "waveform.circle.fill")
                        .resizable()
                        .frame(width: 48, height: 48)
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.appName)
                            .font(.title3.weight(.bold))
                        Text("\(SettingsCopy.About.versionPrefix) \(Self.version)")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            SettingsSection(title: SettingsCopy.About.legalSection) {
                HStack {
                    Text(SettingsCopy.About.license)
                    Spacer()
                    Text(SettingsCopy.About.licenseDetail)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
