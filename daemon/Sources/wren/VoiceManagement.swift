import Foundation

struct VoiceProfileProblem: Equatable, Sendable {
    let profileID: String
    let displayName: String
    let status: VoiceStatus
    let issue: VoiceIssue
}

enum VoicePendingMutation: Equatable, Sendable {
    case activate(id: String, requestID: String)
    case importVoice(id: String, requestID: String, stagingID: String)
    case rename(id: String, requestID: String)
    case delete(id: String, requestID: String)
}

struct VoiceManagementState: Equatable, Sendable {
    let profiles: [VoiceProfile]
    let readyProfiles: [VoiceProfile]
    let incompleteProfiles: [VoiceProfile]
    let invalidProfiles: [VoiceProfile]
    let activeID: String?
    let provenLocalLibrary: URL?
    let importAvailable: Bool
    let mutationsAvailable: Bool
    let pendingMutation: VoicePendingMutation?
    let profileProblems: [VoiceProfileProblem]
    let actionableError: ActionableError?

    init(appState: AppState) {
        profiles = appState.voices?.voices ?? []
        readyProfiles = profiles.filter { $0.status == .ready }
        incompleteProfiles = profiles.filter { $0.status == .incomplete }
        invalidProfiles = profiles.filter { $0.status == .invalid }
        activeID = appState.daemon?.synthesis.activeVoice
        provenLocalLibrary = appState.provenLocalLibrary
        let exactAccess = appState.provenLocalLibrary != nil
        importAvailable = exactAccess && appState.stagedImportAvailable
        mutationsAvailable = exactAccess && appState.stagedImportAvailable
        pendingMutation = Self.pendingMutation(appState.pendingAction)
        profileProblems = profiles.flatMap { profile in
            profile.issues.map { issue in
                VoiceProfileProblem(
                    profileID: profile.id,
                    displayName: profile.displayName,
                    status: profile.status,
                    issue: issue)
            }
        }
        actionableError = appState.actionableError
    }

    private static func pendingMutation(
        _ action: PendingAction?
    ) -> VoicePendingMutation? {
        switch action {
        case .activateVoice(let id, let requestID):
            return .activate(id: id, requestID: requestID)
        case .importVoice(let id, let requestID, let stagingID):
            return .importVoice(
                id: id,
                requestID: requestID,
                stagingID: stagingID)
        case .renameVoice(let id, let requestID):
            return .rename(id: id, requestID: requestID)
        case .deleteVoice(let id, let requestID):
            return .delete(id: id, requestID: requestID)
        default:
            return nil
        }
    }
}

enum SharedVoiceLibrary {
    static func prove(
        endpoint: URL,
        manager: DaemonManager.State?,
        daemon: DaemonStateResponse?,
        configuredLibrary: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let manager, manager.phase == .ready else { return nil }
        let candidate: URL
        switch manager.ownership {
        case .managed:
            guard let library = manager.libraryLocation else { return nil }
            candidate = canonical(library)
        case .connected:
            guard isLoopback(endpoint),
                  let report = daemon?.synthesis.voicesDirectory,
                  report.hasPrefix("/"),
                  let configuredLibrary
            else { return nil }
            let configured = canonical(configuredLibrary)
            let reported = canonical(URL(fileURLWithPath: report))
            guard configured.path == reported.path else { return nil }
            candidate = configured
        case nil:
            return nil
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: candidate.path),
              fileManager.isWritableFile(atPath: candidate.path)
        else { return nil }
        return candidate
    }

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func isLoopback(_ endpoint: URL) -> Bool {
        guard let rawHost = endpoint.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(
            charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        let components = host.split(separator: ".")
        guard components.count == 4,
              components[0] == "127",
              components.allSatisfy({ UInt8($0) != nil })
        else { return false }
        return true
    }
}

struct VoiceImportStage: Equatable, Sendable {
    let id: String
    let directory: URL
}

enum VoiceImportStaging {
    static func validateID(_ id: String) -> Bool {
        guard (1...32).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 45
                || byte == 95
        }
    }

    static func validateSources(wav: URL, transcript: URL) throws {
        try validateRegularFile(
            wav,
            expectedExtension: "wav",
            code: "voice_audio_invalid")
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: wav)
        } catch {
            throw failure(
                code: "voice_audio_invalid",
                message: "The reference WAV could not be read.",
                detail: wav.path)
        }
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12,
              String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE"
        else {
            throw failure(
                code: "voice_audio_invalid",
                message: "The reference audio must be a readable WAV file.",
                detail: wav.path)
        }

        try validateRegularFile(
            transcript,
            expectedExtension: nil,
            code: "voice_transcript_invalid")
        let transcriptData: Data
        do {
            transcriptData = try Data(contentsOf: transcript)
        } catch {
            throw failure(
                code: "voice_transcript_invalid",
                message: "The transcript could not be read.",
                detail: transcript.path)
        }
        guard let text = String(data: transcriptData, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw failure(
                code: "voice_transcript_invalid",
                message: "The transcript must contain UTF-8 text.",
                detail: transcript.path)
        }
    }

    static func stage(
        wav: URL,
        transcript: URL,
        library: URL,
        stagingID: String,
        fileManager: FileManager = .default,
        copyItem: ((URL, URL) throws -> Void)? = nil
    ) throws -> VoiceImportStage {
        try validateSources(wav: wav, transcript: transcript)
        guard !stagingID.isEmpty,
              stagingID != ".",
              stagingID != "..",
              !stagingID.hasPrefix("."),
              !stagingID.contains("/"),
              !stagingID.contains("\\")
        else {
            throw failure(
                code: "staging_id_invalid",
                message: "The import staging ID is unsafe.",
                detail: stagingID)
        }
        let canonicalLibrary = SharedVoiceLibrary.canonical(library)
        let root = canonicalLibrary.appendingPathComponent(
            ".staging",
            isDirectory: true)
        do {
            if fileManager.fileExists(atPath: root.path) {
                let values = try root.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isDirectory == true,
                      values.isSymbolicLink != true
                else {
                    throw failure(
                        code: "voice_staging_failed",
                        message: "The voice staging root is unsafe.",
                        detail: root.path)
                }
            } else {
                try fileManager.createDirectory(
                    at: root,
                    withIntermediateDirectories: false)
            }
            let resolvedRoot = SharedVoiceLibrary.canonical(root)
            guard resolvedRoot.deletingLastPathComponent().path
                    == canonicalLibrary.path
            else {
                throw failure(
                    code: "voice_staging_failed",
                    message: "The voice staging root leaves the library.",
                    detail: root.path)
            }
        } catch let error as VoiceManagementFailure {
            throw error
        } catch {
            throw failure(
                code: "voice_staging_failed",
                message: "The voice staging root is inaccessible.",
                detail: String(describing: error))
        }
        let copy = copyItem ?? { source, destination in
            try fileManager.copyItem(at: source, to: destination)
        }
        let directory = root.appendingPathComponent(
            stagingID,
            isDirectory: true)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw failure(
                code: "staging_id_collision",
                message: "The import staging directory already exists.",
                detail: stagingID)
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false)
            try copy(
                wav,
                directory.appendingPathComponent("reference.wav"))
            try copy(
                transcript,
                directory.appendingPathComponent("transcript.txt"))
        } catch {
            try? fileManager.removeItem(at: directory)
            throw failure(
                code: "voice_staging_failed",
                message: "The voice sources could not be staged.",
                detail: String(describing: error))
        }
        return VoiceImportStage(id: stagingID, directory: directory)
    }

    static func cleanup(
        _ stage: VoiceImportStage,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: stage.directory)
    }

    private static func validateRegularFile(
        _ url: URL,
        expectedExtension: String?,
        code: String
    ) throws {
        guard url.isFileURL,
              expectedExtension == nil
                || url.pathExtension.lowercased() == expectedExtension
        else {
            throw failure(
                code: code,
                message: "The selected source file is invalid.",
                detail: url.path)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isReadableKey,
            ])
        } catch {
            throw failure(
                code: code,
                message: "The selected source file is inaccessible.",
                detail: url.path)
        }
        guard values.isRegularFile == true, values.isReadable == true else {
            throw failure(
                code: code,
                message: "The selected source must be a readable file.",
                detail: url.path)
        }
    }

    private static func failure(
        code: String,
        message: String,
        detail: String?
    ) -> VoiceManagementFailure {
        VoiceManagementFailure(error: ActionableError(
            code: code,
            message: message,
            detail: detail,
            recoverable: true))
    }
}

struct VoiceManagementFailure: Error {
    let error: ActionableError
}
