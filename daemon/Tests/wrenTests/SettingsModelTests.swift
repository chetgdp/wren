import Foundation
import XCTest
@testable import wren

@MainActor
final class SettingsModelTests: XCTestCase {
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsModelTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDestinationSelection() {
        let model = SettingsModel(state: makeState())
        XCTAssertEqual(model.selectedDestination, .server)

        model.selectDestination(.voices)
        XCTAssertEqual(model.selectedDestination, .voices)

        model.selectDestination(.output)
        XCTAssertEqual(model.selectedDestination, .output)

        model.selectDestination(.about)
        XCTAssertEqual(model.selectedDestination, .about)
    }

    func testSelectingActivatingVoiceCallsAction() {
        let model = SettingsModel(state: makeState())
        var activatedId: String?
        model.onActivateVoice = { id in
            activatedId = id
        }

        model.activateVoice(id: "r2")
        XCTAssertEqual(activatedId, "r2")
    }

    func testAddedVoiceAppearsSelectable() {
        let model = SettingsModel(state: makeState(voices: [
            VoiceProfile(id: "c3po", displayName: "C-3PO"),
            VoiceProfile(id: "r2", displayName: "R2"),
        ]))
        XCTAssertEqual(model.state.voices.count, 2)

        var activatedId: String?
        model.onActivateVoice = { id in
            activatedId = id
        }

        // Apply state with newly added voice
        let updatedState = makeState(voices: [
            VoiceProfile(id: "c3po", displayName: "C-3PO"),
            VoiceProfile(id: "r2", displayName: "R2"),
            VoiceProfile(id: "bb8", displayName: "BB-8"),
        ])
        model.apply(state: updatedState)

        XCTAssertEqual(model.state.voices.count, 3)
        let addedVoice = model.state.voices.first { $0.id == "bb8" }
        XCTAssertNotNil(addedVoice)
        XCTAssertEqual(addedVoice?.displayName, "BB-8")

        // Newly added voice is selectable/activatable
        model.activateVoice(id: "bb8")
        XCTAssertEqual(activatedId, "bb8")
    }

    func testAddVoiceCallsHandler() async {
        let model = SettingsModel(state: makeState())
        var receivedArgs: (id: String, name: String, url: URL, text: String)?
        model.onAddVoice = { id, name, url, transcript in
            receivedArgs = (id, name, url, transcript)
            return true
        }

        let dummyURL = URL(fileURLWithPath: "/tmp/voice.wav")
        let ok = await model.addVoice(
            id: "solo",
            name: "Han Solo",
            audioURL: dummyURL,
            transcript: "Never tell me the odds"
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(receivedArgs?.id, "solo")
        XCTAssertEqual(receivedArgs?.name, "Han Solo")
        XCTAssertEqual(receivedArgs?.url, dummyURL)
        XCTAssertEqual(receivedArgs?.text, "Never tell me the odds")
    }

    func testRenameAndDeleteVoiceCallsHandler() {
        let model = SettingsModel(state: makeState())
        var renamed: (String, String)?
        var deletedId: String?
        model.onRenameVoice = { id, name in renamed = (id, name) }
        model.onDeleteVoice = { id in deletedId = id }

        model.renameVoice(id: "r2", displayName: "R2-D2")
        XCTAssertEqual(renamed?.0, "r2")
        XCTAssertEqual(renamed?.1, "R2-D2")

        model.deleteVoice(id: "r2")
        XCTAssertEqual(deletedId, "r2")
    }

    func testUpdateEndpointAndClaimActive() {
        let model = SettingsModel(state: makeState())
        var savedHost: String?
        var claimed = false
        model.onUpdateEndpoint = { host in savedHost = host }
        model.onClaimActive = { claimed = true }

        model.updateEndpoint(host: "newhost:1234")
        XCTAssertEqual(savedHost, "newhost:1234")

        model.claimActive()
        XCTAssertTrue(claimed)
    }

    func testEffectsHandler() {
        let model = SettingsModel(state: makeState())
        var setEffects: Bool?
        model.onSetEffects = { setEffects = $0 }

        model.setEffects(true)
        XCTAssertEqual(setEffects, true)
    }

    func testUserDefaultsIsolation() {
        testDefaults.set(1.4, forKey: "testKey")
        XCTAssertEqual(testDefaults.double(forKey: "testKey"), 1.4)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "testKey"), 0)
    }
}
