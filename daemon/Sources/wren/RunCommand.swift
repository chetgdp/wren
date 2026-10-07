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
        abstract: "Run the menu bar app (default): play this Mac's "
            + "channel from the synthesis server."
    )

    func run() throws {
        MainActor.assumeIsolated {
            let coordinator = AppCoordinator()
            coordinator.start()
            NSApplication.shared.run()
            withExtendedLifetime(coordinator) {}
        }
    }
}
