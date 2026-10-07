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

    func testOutputChoicesWhenDesiredDeviceMissingFallsBackToDefault() {
        let devices = [
            AudioOutputDevice(uid: "a", name: "Speaker A"),
        ]
        let model = WrenMenuModel(state: makeState(
            devices: devices,
            desiredUID: "missing-uid"
        ))
        XCTAssertEqual(
            model.outputChoices.map(\.title),
            ["System Default", "Speaker A", "Missing Device (Unavailable)"]
        )
        // Never nothing checked: System Default is checked when desired missing
        XCTAssertEqual(
            model.outputChoices.map(\.isChecked),
            [true, false, false]
        )
        XCTAssertEqual(
            model.outputChoices.map(\.isEnabled),
            [true, true, false]
        )
    }
    func testLocalServerStatusDisabled() {
        var state = makeState()
        state.host = "127.0.0.1:8765"
        state.localServer = LocalServerState(
            isEnabled: false,
            status: .disabled
        )
        let model = WrenMenuModel(state: state)
        XCTAssertFalse(model.localServer.isOn)
        XCTAssertTrue(model.localServer.isEnabled)
        XCTAssertNil(model.localServer.detail)
        XCTAssertEqual(model.localServer.tone, .normal)
    }

    func testLocalServerStatusStarting() {
        var state = makeState()
        state.host = "127.0.0.1:8765"
        state.localServer = LocalServerState(
            isEnabled: true,
            status: .starting
        )
        let model = WrenMenuModel(state: state)
        XCTAssertTrue(model.localServer.isOn)
        XCTAssertTrue(model.localServer.isEnabled)
        XCTAssertEqual(model.localServer.detail, "Loading model…")
        XCTAssertEqual(model.localServer.tone, .normal)
    }

    func testLocalServerStatusRunning() {
        var state = makeState()
        state.host = "127.0.0.1:8765"
        state.localServer = LocalServerState(
            isEnabled: true,
            status: .running
        )
        let model = WrenMenuModel(state: state)
        XCTAssertTrue(model.localServer.isOn)
        XCTAssertTrue(model.localServer.isEnabled)
        XCTAssertEqual(model.localServer.detail, "Running")
        XCTAssertEqual(model.localServer.tone, .normal)
    }

    func testLocalServerStatusExternal() {
        var state = makeState()
        state.host = "127.0.0.1:8765"
        state.localServer = LocalServerState(
            isEnabled: true,
            status: .external
        )
        let model = WrenMenuModel(state: state)
        XCTAssertTrue(model.localServer.isOn)
        XCTAssertTrue(model.localServer.isEnabled)
        XCTAssertEqual(model.localServer.detail, "Using existing server")
        XCTAssertEqual(model.localServer.tone, .normal)
    }

    func testLocalServerStatusCrashed() {
        var state = makeState()
        state.host = "127.0.0.1:8765"
        state.localServer = LocalServerState(
            isEnabled: true,
            status: .crashed("Segmentation fault", retryIn: 4.0)
        )
        let model = WrenMenuModel(state: state)
        XCTAssertTrue(model.localServer.isOn)
        XCTAssertTrue(model.localServer.isEnabled)
        XCTAssertEqual(
            model.localServer.detail,
            "Crashed: Segmentation fault, retrying in 4s"
        )
        XCTAssertEqual(model.localServer.tone, .error)
    }

    func testLocalServerStatusUnavailableNonLoopbackHost() {
        var state = makeState()
        state.host = "192.168.1.50:8765"
        state.localServer = LocalServerState(
            isEnabled: true,
            status: .unavailable("Host '192.168.1.50:8765' is not loopback")
        )
        let model = WrenMenuModel(state: state)
        XCTAssertTrue(model.localServer.isOn)
        XCTAssertFalse(
            model.localServer.isEnabled,
            "Toggle should be disabled when host is non-loopback"
        )
        XCTAssertEqual(
            model.localServer.detail,
            "Host '192.168.1.50:8765' is not loopback"
        )
        XCTAssertEqual(model.localServer.tone, .warning)
    }

    func testLocalServerStatusUnavailableScriptMissing() {
        var state = makeState()
        state.host = "127.0.0.1:8765"
        state.localServer = LocalServerState(
            isEnabled: true,
            status: .unavailable("Script /opt/serve.sh not found")
        )
        let model = WrenMenuModel(state: state)
        XCTAssertTrue(model.localServer.isOn)
        XCTAssertTrue(
            model.localServer.isEnabled,
            "Toggle stays enabled on loopback even if script missing"
        )
        XCTAssertEqual(
            model.localServer.detail,
            "Script /opt/serve.sh not found"
        )
        XCTAssertEqual(model.localServer.tone, .warning)
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

    func testClickingStatusItemOpensMenu() throws {
        let bar = WrenMenuBar()
        XCTAssertTrue(bar.statusItem.menu === bar.menu)
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

    func testNoReRenderWhenModelEqual() throws {
        let bar = WrenMenuBar()
        let state = makeState(activeVoice: "c3po")
        bar.render(state)
        let voiceRebuilds = bar.voiceRebuilds
        let outputRebuilds = bar.outputRebuilds
        // Re-rendering with identical state must be a no-op
        bar.render(state)
        XCTAssertEqual(bar.voiceRebuilds, voiceRebuilds)
        XCTAssertEqual(bar.outputRebuilds, outputRebuilds)
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

    func testSpeakingRateSliderRendersModelAndSendsAction() throws {
        let bar = WrenMenuBar()
        var actions: [WrenMenuBar.Action] = []
        bar.onAction = { actions.append($0) }
        var state = makeState()
        state.localPlayer.speakingRate = 1.75
        bar.render(state)
        XCTAssertEqual(bar.rateView.value, 1.75)

        bar.rateView.onChange?(2.25)
        XCTAssertEqual(actions, [.setSpeakingRate(2.25)])
    }
}

