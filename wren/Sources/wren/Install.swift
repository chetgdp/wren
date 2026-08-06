import ArgumentParser
import Foundation

/// Manage wren's LaunchAgent so the app starts at login. A plain plist
/// rather than SMAppService, mirroring otis: same mechanism on both
/// daemons, no bundle-only API.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register wren to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8))
            throw ExitCode(64)
        }
        if uninstall {
            try removeAgent()
        } else {
            try writeAgent()
        }
    }

    private static let label = "com.digimata.wren"

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private func writeAgent() throws {
        let binary = try resolveBinaryPath()
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/wren.out.log",
            "StandardErrorPath": "/tmp/wren.err.log",
        ]
        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)

        _ = runLaunchctl(["bootout", "gui/\(getuid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(getuid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8))
        }
        print("launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
    }

    private func removeAgent() throws {
        let url = plistURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("nothing to remove (no agent at \(url.path))")
            return
        }
        _ = runLaunchctl(["bootout", "gui/\(getuid())", url.path])
        try FileManager.default.removeItem(at: url)
        print("launch-at-login removed")
    }

    /// The bundle binary is the canonical install (bundle.sh symlinks
    /// ~/.local/bin/wren into it); a bare dev binary is honored with a note.
    private func resolveBinaryPath() throws -> String {
        let bundled = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Wren.app/Contents/MacOS/wren").path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let argv0 = CommandLine.arguments.first ?? "wren"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: no Wren.app; using \(argv0)\n".utf8))
            return argv0
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the wren binary; run scripts/bundle.sh first.\n".utf8))
        throw ExitCode(1)
    }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        return (task.terminationStatus, err)
    }
}
