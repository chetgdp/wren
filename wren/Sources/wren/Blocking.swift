import Foundation

/// Bridge for the CLI subcommands: block the calling thread on one async
/// HTTP round-trip. The command tree is sync on purpose - an async @main
/// runs every subcommand on the concurrency pool instead of the real main
/// thread, and NSApplication.run() (the `run` subcommand) traps anywhere
/// but on it.
func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            box.result = .success(try await body())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result!.get()
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
