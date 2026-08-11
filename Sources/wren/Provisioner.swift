import Foundation

/// First-run setup: everything serve.py needs that cannot ship inside the
/// app bundle lands in Application Support. Idempotent - every step checks
/// before doing work, so launches after the first are instant.
///
///   ~/Library/Application Support/voice-ml/
///     env/      python env for serve.py (built by the bundled uv)
///     models/   talker + tokenizer GGUFs (2.2 GB; downloaded, never bundled)
///     voices/   ref wav+txt pairs, seeded with the bundled default voice
///     config.json  serve.py's own config file (written by the daemon)
enum ProvisionStep: Equatable {
    case pythonEnv
    case model(name: String, done: Int64, total: Int64)
    case ready
}

struct ProvisionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The two GGUFs serve.py's qwentts backend loads; same files the runbook
/// fetches onto the Linux box.
struct ModelFile {
    let name: String
    let url: URL

    static let all = [
        ModelFile(
            name: "qwen-talker-1.7b-base-Q8_0.gguf",
            url: URL(string: "https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF/resolve/main/qwen-talker-1.7b-base-Q8_0.gguf")!),
        ModelFile(
            name: "qwen-tokenizer-12hz-Q8_0.gguf",
            url: URL(string: "https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF/resolve/main/qwen-tokenizer-12hz-Q8_0.gguf")!),
    ]
}

/// Bundle-relative and Application Support-relative paths in one place, so
/// the spawn command, the provisioner, and the tests agree on the layout.
struct WrenPaths {
    let resources: URL
    let appSupport: URL

    static func standard() -> WrenPaths {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice-ml", isDirectory: true)
        // resourceURL exists even for a bare binary (its directory); the
        // server-files check below is what actually gates spawning.
        let resources = Bundle.main.resourceURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
        return WrenPaths(resources: resources, appSupport: appSupport)
    }

    var servePy: URL { resources.appendingPathComponent("server/serve.py") }
    var requirements: URL { resources.appendingPathComponent("server/requirements.txt") }
    var bundledUv: URL { resources.appendingPathComponent("uv") }
    var engineBinary: URL { resources.appendingPathComponent("engine/tts-server") }
    var bundledVoices: URL { resources.appendingPathComponent("voices") }

    var env: URL { appSupport.appendingPathComponent("env") }
    var python: URL { env.appendingPathComponent("bin/python3") }
    var models: URL { appSupport.appendingPathComponent("models") }
    var voices: URL { appSupport.appendingPathComponent("voices") }
    var configFile: URL { appSupport.appendingPathComponent("config.json") }
    var defaultVoiceWav: URL { voices.appendingPathComponent("c3po_god.wav") }

    /// The app can only spawn a daemon if the bundle carries the server;
    /// a bare dev binary (swift run) adopts an existing daemon instead.
    var hasServerFiles: Bool {
        FileManager.default.fileExists(atPath: servePy.path)
            && FileManager.default.fileExists(atPath: engineBinary.path)
    }
}

final class Provisioner: @unchecked Sendable {
    private let paths: WrenPaths
    private let progress: @Sendable (ProvisionStep) -> Void

    init(paths: WrenPaths, progress: @escaping @Sendable (ProvisionStep) -> Void) {
        self.paths = paths
        self.progress = progress
    }

    /// Run every step; returns only when serve.py can start. Blocking by
    /// design - call it off the main thread.
    func ensure() throws {
        let fm = FileManager.default
        for dir in [paths.appSupport, paths.models, paths.voices] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try seedVoices()
        try ensurePythonEnv()
        try ensureModels()
        progress(.ready)
    }

    private func seedVoices() throws {
        let fm = FileManager.default
        guard let bundled = try? fm.contentsOfDirectory(
            at: paths.bundledVoices, includingPropertiesForKeys: nil) else { return }
        for source in bundled {
            let dest = paths.voices.appendingPathComponent(source.lastPathComponent)
            // Never overwrite: the user's edited voices win over the seed.
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: source, to: dest)
            }
        }
    }

    private func ensurePythonEnv() throws {
        let fm = FileManager.default
        // The requirements file doubles as the env's version stamp: a new
        // bundle with different pins rebuilds the env, an unchanged one
        // skips it.
        let stamp = paths.env.appendingPathComponent(".requirements")
        let wanted = try Data(contentsOf: paths.requirements)
        if fm.fileExists(atPath: paths.python.path),
           let have = try? Data(contentsOf: stamp), have == wanted {
            return
        }
        progress(.pythonEnv)
        let uv = try resolveUv()
        // Pinned interpreter: uv fetches a managed 3.12 if the machine has
        // none, so a bare Mac needs no python install of its own.
        try run(uv, ["venv", "--allow-existing", "--python", "3.12", paths.env.path])
        try run(uv, ["pip", "install", "--python", paths.python.path,
                     "-r", paths.requirements.path])
        try wanted.write(to: stamp)
    }

    private func resolveUv() throws -> URL {
        let fm = FileManager.default
        var candidates = [paths.bundledUv]
        let home = fm.homeDirectoryForCurrentUser
        candidates += [
            home.appendingPathComponent(".local/bin/uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv"),
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw ProvisionError("uv not found (bundle is missing Resources/uv)")
    }

    private func ensureModels() throws {
        for model in ModelFile.all {
            let dest = paths.models.appendingPathComponent(model.name)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            try download(model, to: dest)
        }
    }

    private func download(_ model: ModelFile, to dest: URL) throws {
        // .part + rename so an interrupted download never leaves a
        // truncated file a rerun would skip over (fetch-models.sh pattern).
        let partial = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)

        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        let delegate = DownloadProgressDelegate { [progress] downloaded, total in
            progress(.model(name: model.name, done: downloaded, total: total))
        }
        let session = URLSession(
            configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: model.url) { temp, response, error in
            defer { done.signal() }
            if let error {
                result.error = ProvisionError("\(model.name): \(error.localizedDescription)")
                return
            }
            guard let temp,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result.error = ProvisionError("\(model.name): HTTP \(status)")
                return
            }
            do {
                try FileManager.default.moveItem(at: temp, to: partial)
                try FileManager.default.moveItem(at: partial, to: dest)
            } catch {
                result.error = ProvisionError("\(model.name): \(error.localizedDescription)")
            }
        }
        task.resume()
        done.wait()
        if let error = result.error { throw error }
    }

    private func run(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            throw ProvisionError(
                "\(tool.lastPathComponent) \(arguments.first ?? "") failed: \(detail)")
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    var error: Error?
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable {
    private let onProgress: (Int64, Int64) -> Void
    private var lastReport = Date.distantPast

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Byte callbacks arrive far faster than a menu bar needs repainting.
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.5 else { return }
        lastReport = now
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Completion handled in the task's completion closure; the protocol
        // just requires this method to exist.
    }
}
