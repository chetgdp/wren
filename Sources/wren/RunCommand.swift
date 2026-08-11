import AppKit
import ArgumentParser
import Foundation

/// The menu bar app: what Spotlight launches (the default subcommand).
/// Sync entry point on purpose, same as otis: an async @main runs
/// everything as blocks on the main dispatch queue, and app.run() inside a
/// block wedges the queue forever.
struct RunApp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu bar app (default): manage and play the TTS daemon."
    )

    /// Locals would deallocate when run() reaches app.run(); anchor the
    /// controller and signal sources for the process's life.
    @MainActor private static var appRefs: [Any] = []

    func run() throws {
        Task { @MainActor in
            NSApplication.shared.setActivationPolicy(.accessory)
            let controller = AppController()
            RunApp.appRefs.append(controller)

            // Ctrl-C in a terminal and SIGTERM from launchctl both go
            // through NSApp.terminate so willTerminate kills the child.
            for sig in [SIGINT, SIGTERM] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { NSApp.terminate(nil) }
                source.resume()
                RunApp.appRefs.append(source)
            }
        }
        NSApplication.shared.run()
    }
}
