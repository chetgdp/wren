import AppKit
import Foundation
import XCTest
@testable import wren

@MainActor
final class MenuModelTests: XCTestCase {
    func testCheckmarkFollowsActiveVoice() {
        let model = WrenMenuModel(state: makeState(activeVoice: "r2"))
        XCTAssertEqual(model.voices.map(\.isChecked), [false, true])
        XCTAssertEqual(model.voiceBadge, "R2")
    }

    func testCheckmarkChangeKeepsStructure() {
        let a = WrenMenuModel(state: makeState(activeVoice: "c3po"))
        let b = WrenMenuModel(state: makeState(activeVoice: "r2"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.structure, b.structure)

        let added = WrenMenuModel(state: makeState(voices: [
            VoiceProfile(id: "c3po", displayName: "C-3PO"),
            VoiceProfile(id: "r2", displayName: "R2"),
            VoiceProfile(id: "bb8", displayName: "BB-8"),
        ]))
        XCTAssertNotEqual(a.structure, added.structure)
    }

    func testPlayingHereAndElsewhere() {
        let here = WrenMenuModel(state: makeState())
        XCTAssertEqual(here.clientTitle, "Playing here")
        XCTAssertFalse(here.showsPlayHere)

        let there = WrenMenuModel(state: makeState(
            activeClient: ClientInfo(channel: "mac-b", label: "Studio")
        ))
        XCTAssertEqual(there.clientTitle, "Playing on Studio")
        XCTAssertTrue(there.showsPlayHere)

        let nobody = WrenMenuModel(state: makeState(activeClient: nil))
        XCTAssertEqual(nobody.clientTitle, "No Mac is playing")
        XCTAssertTrue(nobody.showsPlayHere)
    }

    func testConnectionStates() {
        let offline = WrenMenuModel(state: makeState(
            status: .unreachable("server not reachable at server:8765"),
            activeClient: nil
        ))
        XCTAssertEqual(offline.status.title, "Unreachable")
        XCTAssertEqual(offline.status.tone, .error)
        XCTAssertFalse(offline.showsPlayHere, "cannot claim while offline")
        XCTAssertFalse(offline.isConnected)

        let connected = WrenMenuModel(state: makeState())
        XCTAssertEqual(connected.status.title, "Connected")
        XCTAssertEqual(connected.status.detail, "server:8765")
    }

    func testOutputChoicesCheckDesiredDevice() {
        let devices = [
            AudioOutputDevice(uid: "a", name: "A"),
            AudioOutputDevice(uid: "b", name: "B"),
        ]
        let model = WrenMenuModel(state: makeState(
            devices: devices,
            desiredUID: "b"
        ))
        XCTAssertEqual(model.outputChoices.map(\.title),
                       ["System Default", "A", "B"])
        XCTAssertEqual(model.outputChoices.map(\.isChecked),
                       [false, false, true])
        XCTAssertEqual(model.outputBadge, "B")
        XCTAssertEqual(model.structure.outputKeys, ["", "a", "b"])
    }
}

@MainActor
final class MenuBarRenderTests: XCTestCase {
    private func click(_ item: NSMenuItem) {
        NSApplication.shared.sendAction(
            item.action!,
            to: item.target,
            from: item
        )
    }

    private func voiceItem(_ bar: WrenMenuBar, _ title: String)
        -> NSMenuItem? {
        bar.menu.items.first { $0.title == "Voice" }?.submenu?.items
            .first { $0.title == title }
    }

    func testUnchangedStructureUpdatesInPlace() throws {
        let bar = WrenMenuBar()
        bar.render(makeState(activeVoice: "c3po"))
        XCTAssertEqual(bar.voiceRebuilds, 1)
        XCTAssertEqual(bar.outputRebuilds, 1)
        let item = try XCTUnwrap(voiceItem(bar, "R2"))
        let effects = try XCTUnwrap(
            bar.menu.items.first { $0.title == "Effects" }
        )

        bar.render(makeState(activeVoice: "r2", effects: true))
        XCTAssertEqual(bar.voiceRebuilds, 1, "no rebuild for a checkmark")
        XCTAssertEqual(bar.outputRebuilds, 1)
        XCTAssertTrue(voiceItem(bar, "R2") === item, "same item instance")
        XCTAssertEqual(item.state, .on)
        XCTAssertEqual(voiceItem(bar, "C-3PO")?.state, .off)
        XCTAssertTrue(
            bar.menu.items.first { $0.title == "Effects" } === effects
        )
        XCTAssertEqual(effects.state, .on)

        let count = bar.menu.items.count
        bar.render(makeState(activeVoice: "r2", effects: true))
        XCTAssertEqual(bar.menu.items.count, count)
    }

    func testAddedVoiceRebuildsAndIsClickable() throws {
        let bar = WrenMenuBar()
        var actions: [WrenMenuBar.Action] = []
        bar.onAction = { actions.append($0) }
        bar.render(makeState())
        bar.render(makeState(voices: [
            VoiceProfile(id: "c3po", displayName: "C-3PO"),
            VoiceProfile(id: "r2", displayName: "R2"),
            VoiceProfile(id: "bb8", displayName: "BB-8"),
        ]))
        XCTAssertEqual(bar.voiceRebuilds, 2)
        let item = try XCTUnwrap(voiceItem(bar, "BB-8"))
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(item.isEnabled)
        NSApplication.shared.sendAction(action, to: item.target, from: item)
        XCTAssertEqual(actions, [.activateVoice(id: "bb8")])
    }

    func testPlayHereVisibilityAndAction() throws {
        let bar = WrenMenuBar()
        var actions: [WrenMenuBar.Action] = []
        bar.onAction = { actions.append($0) }
        bar.render(makeState())
        let playHere = try XCTUnwrap(
            bar.menu.items.first { $0.title == "Play here" }
        )
        XCTAssertTrue(playHere.isHidden)
        XCTAssertTrue(bar.menu.items.contains { $0.title == "Playing here" })

        bar.render(makeState(
            activeClient: ClientInfo(channel: "mac-b", label: "Studio")
        ))
        XCTAssertFalse(playHere.isHidden)
        XCTAssertTrue(
            bar.menu.items.contains { $0.title == "Playing on Studio" }
        )
        NSApplication.shared.sendAction(
            playHere.action!,
            to: playHere.target,
            from: playHere
        )
        XCTAssertEqual(actions, [.claimActive])
    }

    func testEffectsClickTogglesFromModel() throws {
        let bar = WrenMenuBar()
        var actions: [WrenMenuBar.Action] = []
        bar.onAction = { actions.append($0) }
        bar.render(makeState(effects: false))
        let effects = try XCTUnwrap(
            bar.menu.items.first { $0.title == "Effects" }
        )
        click(effects)
        bar.render(makeState(effects: true))
        click(effects)
        XCTAssertEqual(actions, [.setEffects(true), .setEffects(false)])
    }
}

@MainActor
final class FakeSettingsSink: SettingsWindowActionSink {
    var calls: [String] = []

    func updateEndpoint(host: String) {
        calls.append("endpoint \(host)")
    }
    func claimActive() async { calls.append("claim") }
    func activateVoice(id: String) async { calls.append("use \(id)") }
    func renameVoice(id: String, displayName: String) async {
        calls.append("rename \(id) \(displayName)")
    }
    func deleteVoice(id: String) async { calls.append("delete \(id)") }
    func addVoice(
        id: String,
        name: String,
        audioURL: URL,
        transcript: String
    ) async -> Bool {
        calls.append("add \(id) \(name) \(audioURL.lastPathComponent) "
            + transcript)
        return true
    }
    func setOutputDevice(_ device: AudioOutputDevice?) async {
        calls.append("output \(device?.uid ?? "default")")
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testViewModelRows() {
        let model = SettingsViewModel(state: makeState(activeVoice: "r2"))
        XCTAssertEqual(model.voices.map(\.isActive), [false, true])
        XCTAssertEqual(model.voices.map(\.canDelete), [true, false])
    }

    func testPrefillsEndpointAndSaves() {
        let sink = FakeSettingsSink()
        let window = SettingsWindowController(
            state: makeState(),
            actionSink: sink
        )
        XCTAssertEqual(window.hostField.stringValue, "server:8765")
        window.hostField.stringValue = "box:9"
        window.saveEndpoint()
        XCTAssertEqual(sink.calls, ["endpoint box:9"])
    }

    func testEveryVoiceRowActivatesIncludingNewOnes() async throws {
        let sink = FakeSettingsSink()
        let window = SettingsWindowController(
            state: makeState(),
            actionSink: sink
        )
        window.update(state: makeState(voices: [
            VoiceProfile(id: "c3po", displayName: "C-3PO"),
            VoiceProfile(id: "r2", displayName: "R2"),
            VoiceProfile(id: "bb8", displayName: "BB-8"),
        ]))
        XCTAssertEqual(window.voiceTable.numberOfRows, 3)
        for row in 0..<3 {
            let view = try XCTUnwrap(window.tableView(
                window.voiceTable,
                viewFor: nil,
                row: row
            ) as? NSStackView)
            let use = try XCTUnwrap(view.views.compactMap {
                $0 as? NSButton
            }.first)
            if row == 0 {
                XCTAssertFalse(use.isEnabled, "active voice")
                XCTAssertEqual(use.title, "Active")
            } else {
                XCTAssertTrue(use.isEnabled)
                window.useVoice(use)
            }
        }
        await settle()
        XCTAssertEqual(sink.calls, ["use r2", "use bb8"])
    }

    func testAddVoiceUploadsAndClearsForm() async {
        let sink = FakeSettingsSink()
        let window = SettingsWindowController(
            state: makeState(),
            actionSink: sink
        )
        window.addIdField.stringValue = "bb8"
        window.addNameField.stringValue = "BB-8"
        window.addTranscriptField.stringValue = "beep boop"
        window.chosenAudioURL = URL(fileURLWithPath: "/tmp/clip.wav")
        window.submitAddVoice()
        await settle()
        XCTAssertEqual(sink.calls, ["add bb8 BB-8 clip.wav beep boop"])
        XCTAssertEqual(window.addIdField.stringValue, "")
        XCTAssertNil(window.chosenAudioURL)
    }

    func testAddVoiceRequiresAllFields() async {
        let sink = FakeSettingsSink()
        let window = SettingsWindowController(
            state: makeState(),
            actionSink: sink
        )
        window.addIdField.stringValue = "bb8"
        window.submitAddVoice()
        await settle()
        XCTAssertTrue(sink.calls.isEmpty)
    }

    func testOutputPopupListsDevicesAndSurvivesPolls() async {
        let devices = [AudioOutputDevice(uid: "a", name: "A")]
        let sink = FakeSettingsSink()
        let window = SettingsWindowController(
            state: makeState(devices: devices),
            actionSink: sink
        )
        XCTAssertEqual(window.outputPopUp.itemTitles, ["System Default", "A"])
        let first = window.outputPopUp.item(at: 1)
        window.update(state: makeState(
            status: .unreachable("x"),
            devices: devices
        ))
        XCTAssertTrue(window.outputPopUp.item(at: 1) === first,
                      "unrelated updates keep popup items")
        window.outputPopUp.selectItem(at: 1)
        window.outputChanged()
        await settle()
        XCTAssertEqual(sink.calls, ["output a"])
    }

    func testErrorAndClientLabels() {
        var state = makeState(
            activeClient: ClientInfo(channel: "mac-b", label: "Studio")
        )
        state.lastError = "server returned 409 voice_active: busy"
        let window = SettingsWindowController(
            state: state,
            actionSink: FakeSettingsSink()
        )
        XCTAssertEqual(window.activeClientLabel.stringValue,
                       "Playing on Studio")
        XCTAssertFalse(window.playHereButton.isHidden)
        XCTAssertFalse(window.errorLabel.isHidden)
        XCTAssertTrue(window.errorLabel.stringValue.contains("voice_active"))
    }
}
