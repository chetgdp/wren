import AppKit
import XCTest
@testable import wren

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testControllerRendersProviderThenAuthoritativeUpdates() {
        _ = NSApplication.shared
        let initial = SettingsStateFixture().makeState()
        let sink = SettingsWindowActionRecorder()
        let controller = SettingsWindowController(
            stateProvider: { initial },
            actionSink: sink)
        defer { controller.close() }

        XCTAssertEqual(
            controller.presentedViewModel.activeVoiceID,
            "c3po")

        var updatedFixture = SettingsStateFixture()
        updatedFixture.activeVoice = "wintermute"
        updatedFixture.profiles = [
            settingsProfile(
                id: "c3po",
                name: "C-3PO",
                status: .ready),
            settingsProfile(
                id: "wintermute",
                name: "Wintermute",
                status: .ready)
        ]
        controller.update(state: updatedFixture.makeState())

        XCTAssertEqual(
            controller.presentedViewModel.activeVoiceID,
            "wintermute")
        XCTAssertTrue(
            controller.presentedViewModel
                .voice(id: "wintermute")?.isActive == true)
        XCTAssertTrue(sink.actions.isEmpty)
    }

    func testEveryMutationRoutesThroughInjectedSink() async {
        _ = NSApplication.shared
        let state = SettingsStateFixture().makeState()
        let sink = SettingsWindowActionRecorder()
        let controller = SettingsWindowController(
            stateProvider: { state },
            actionSink: sink)
        defer { controller.close() }
        let output = AudioOutputDevice(uid: "desk", name: "Desk DAC")
        let voiceImport = SettingsVoiceImport(
            wav: URL(fileURLWithPath: "/chosen/nova.wav"),
            transcript: URL(fileURLWithPath: "/chosen/nova.txt"),
            displayName: "Nova",
            id: "nova")

        await controller.perform(.refresh)
        await controller.perform(.activateVoice(id: "wintermute"))
        await controller.perform(.importVoice(voiceImport))
        await controller.perform(
            .renameVoice(id: "wintermute", name: "Wintermute II"))
        await controller.perform(.deleteVoice(id: "obsolete"))
        await controller.perform(.setOutputDevice(output))
        await controller.perform(.setOutputDevice(nil))
        await controller.perform(.retryStartup)
        await controller.perform(.resetInvalidSettings)

        XCTAssertEqual(sink.actions, [
            .refresh,
            .activateVoice(id: "wintermute"),
            .importVoice(voiceImport),
            .renameVoice(
                id: "wintermute",
                name: "Wintermute II"),
            .deleteVoice(id: "obsolete"),
            .setOutputDevice(output),
            .setOutputDevice(nil),
            .retryStartup,
            .resetInvalidSettings
        ])
    }
}

@MainActor
private final class SettingsWindowActionRecorder:
    SettingsWindowActionSink {
    private(set) var actions: [SettingsWindowAction] = []

    func refresh() async {
        actions.append(.refresh)
    }

    func activateVoice(id: String) async {
        actions.append(.activateVoice(id: id))
    }

    func importVoice(
        wav: URL,
        transcript: URL,
        name: String,
        id: String
    ) async {
        actions.append(.importVoice(SettingsVoiceImport(
            wav: wav,
            transcript: transcript,
            displayName: name,
            id: id)))
    }

    func renameVoice(id: String, name: String) async {
        actions.append(.renameVoice(id: id, name: name))
    }

    func deleteVoice(id: String) async {
        actions.append(.deleteVoice(id: id))
    }

    func setOutputDevice(_ device: AudioOutputDevice?) async {
        actions.append(.setOutputDevice(device))
    }

    func retryStartup() {
        actions.append(.retryStartup)
    }

    func resetInvalidSettings() {
        actions.append(.resetInvalidSettings)
    }
}

