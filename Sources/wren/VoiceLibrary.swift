import Foundation

/// The voices the daemon can speak with: wav+txt basename pairs inside the
/// config's voices_dir. Pure directory scan so it is unit-testable.
enum VoiceLibrary {
    static func voices(in dir: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        let names = Set(entries.map(\.lastPathComponent))
        return entries
            .filter { $0.pathExtension == "wav" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { names.contains("\($0).txt") }
            .sorted()
    }

    /// Config paths may be tilde-relative; the daemon expands them when
    /// resolving ref audio, so the menu's scan must expand the same way.
    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
