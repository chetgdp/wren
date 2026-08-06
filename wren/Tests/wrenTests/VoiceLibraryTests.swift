import XCTest
@testable import wren

final class VoiceLibraryTests: XCTestCase {
    func testListsOnlyCompletePairsSorted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wren-voices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["zed.wav", "zed.txt", "abe.wav", "abe.txt",
                     "orphan.wav", "stray.txt", "notes.md"] {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path, contents: Data())
        }

        XCTAssertEqual(VoiceLibrary.voices(in: dir), ["abe", "zed"])
    }

    func testMissingDirectoryIsEmptyNotFatal() {
        let gone = URL(fileURLWithPath: "/nonexistent/wren-voices")
        XCTAssertEqual(VoiceLibrary.voices(in: gone), [])
    }

    func testTildeExpansion() {
        XCTAssertEqual(
            VoiceLibrary.expand("~/voices").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("voices").path)
    }
}
