import Foundation
import ServiceManagement

struct LoginItemState: Equatable, Sendable {
    let isAvailable: Bool
    let isEnabled: Bool
    let error: String?
}

enum LoginItemServiceStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol LoginItemService: AnyObject {
    var status: LoginItemServiceStatus { get }
    func register() throws
    func unregister() throws
}

protocol LoginItemProviding: AnyObject {
    func refresh() -> LoginItemState
    func setEnabled(_ enabled: Bool) -> LoginItemState
}

final class NativeLoginItem: LoginItemProviding {
    static let legacyPlistURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/LaunchAgents",
            isDirectory: true)
        .appendingPathComponent("com.heavyetl.wren.plist")

    private let service: LoginItemService?
    private let legacyPlistURL: URL
    private let legacyPlistExists: (URL) -> Bool
    private let removeLegacyPlist: (URL) throws -> Void

    convenience init(bundle: Bundle = .main) {
        let service: LoginItemService?
        if bundle.bundleURL.pathExtension == "app",
            bundle.bundleIdentifier == WrenDefaults.bundleID {
            service = MainAppLoginItemService()
        } else {
            service = nil
        }
        self.init(
            service: service,
            legacyPlistURL: Self.legacyPlistURL,
            legacyPlistExists: { url in
                FileManager.default.fileExists(atPath: url.path)
            },
            removeLegacyPlist: { url in
                let manager = FileManager.default
                guard manager.fileExists(atPath: url.path) else {
                    return
                }
                try manager.removeItem(at: url)
            })
    }

    init(
        service: LoginItemService?,
        legacyPlistURL: URL,
        legacyPlistExists: @escaping (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        },
        removeLegacyPlist: @escaping (URL) throws -> Void
    ) {
        self.service = service
        self.legacyPlistURL = legacyPlistURL
        self.legacyPlistExists = legacyPlistExists
        self.removeLegacyPlist = removeLegacyPlist
    }

    func refresh() -> LoginItemState {
        guard hasLegacyItem else { return state(error: nil) }
        return migrateLegacyItem()
    }

    func setEnabled(_ enabled: Bool) -> LoginItemState {
        guard service != nil else {
            return state(
                error: "Launch at Login requires the Wren app bundle.")
        }
        if enabled {
            return hasLegacyItem
                ? migrateLegacyItem()
                : enableNativeItem()
        }
        return disableAllItems()
    }

    private var hasLegacyItem: Bool {
        legacyPlistExists(legacyPlistURL)
    }

    private func enableNativeItem() -> LoginItemState {
        guard let service else {
            return state(
                error: "Launch at Login requires the Wren app bundle.")
        }
        do {
            if service.status == .notRegistered
                || service.status == .notFound {
                try service.register()
            }
            return state(error: nil)
        } catch {
            return state(error: String(describing: error))
        }
    }

    private func migrateLegacyItem() -> LoginItemState {
        guard let service else {
            return state(
                error: "The legacy login item remains active. Open the "
                    + "Wren app to finish migration.")
        }
        do {
            if service.status == .notRegistered
                || service.status == .notFound {
                try service.register()
            }
            guard service.status == .enabled else {
                return state(error: migrationPendingMessage(service.status))
            }
            try removeLegacyPlist(legacyPlistURL)
            return state(error: nil)
        } catch {
            return state(
                error: "Launch at Login migration failed: "
                    + "\(error). The legacy login item remains active.")
        }
    }

    private func disableAllItems() -> LoginItemState {
        guard let service else {
            return state(
                error: "Launch at Login requires the Wren app bundle.")
        }
        do {
            if service.status == .enabled
                || service.status == .requiresApproval {
                try service.unregister()
            }
            if hasLegacyItem {
                try removeLegacyPlist(legacyPlistURL)
            }
            return state(error: nil)
        } catch {
            return state(
                error: "Launch at Login could not be turned off: \(error).")
        }
    }

    private func migrationPendingMessage(
        _ status: LoginItemServiceStatus
    ) -> String {
        if status == .requiresApproval {
            return "Allow Wren in Login Items in System Settings. "
                + "The legacy login item remains active until approval."
        }
        return "The native login item could not be enabled. "
            + "The legacy login item remains active."
    }

    private func state(error: String?) -> LoginItemState {
        let legacyEnabled = hasLegacyItem
        guard let service else {
            return LoginItemState(
                isAvailable: false,
                isEnabled: legacyEnabled,
                error: error)
        }
        switch service.status {
        case .enabled:
            return LoginItemState(
                isAvailable: true,
                isEnabled: true,
                error: error)
        case .notRegistered:
            return LoginItemState(
                isAvailable: true,
                isEnabled: legacyEnabled,
                error: error ?? legacyWarning(legacyEnabled))
        case .requiresApproval:
            let approval = legacyEnabled
                ? migrationPendingMessage(.requiresApproval)
                : "Allow Wren in Login Items in System Settings."
            return LoginItemState(
                isAvailable: true,
                isEnabled: legacyEnabled,
                error: error ?? approval)
        case .notFound:
            return LoginItemState(
                isAvailable: true,
                isEnabled: legacyEnabled,
                error: error ?? legacyWarning(legacyEnabled))
        }
    }

    private func legacyWarning(_ enabled: Bool) -> String? {
        guard enabled else { return nil }
        return "The legacy login item remains active while Wren finishes "
            + "migration."
    }
}

private final class MainAppLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp

    var status: LoginItemServiceStatus {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
