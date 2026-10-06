import Foundation

/// Where the server endpoint is persisted. A protocol so tests never touch
/// the user's real defaults domain.
protocol EndpointPersisting: AnyObject {
    var savedHost: String? { get set }
}

enum WrenDefaults {
    static let bundleID = "com.heavyetl.wren"

    /// The CLI usually runs through a symlink outside the app bundle, so
    /// `UserDefaults.standard` would resolve to a different domain than the
    /// app's. Both processes must read the host the Settings window saved.
    /// Inside the app the bundle domain already is that suite, and
    /// UserDefaults refuses a suite named after the running bundle.
    static var shared: UserDefaults {
        if Bundle.main.bundleIdentifier == bundleID {
            return .standard
        }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }
}

/// UserDefaults, so the CLI and the app share the saved host.
final class SystemEndpointStore: EndpointPersisting {
    static let hostKey = "server_host"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = WrenDefaults.shared) {
        self.defaults = defaults
    }

    var savedHost: String? {
        get { defaults.string(forKey: Self.hostKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Self.hostKey)
            } else {
                defaults.removeObject(forKey: Self.hostKey)
            }
        }
    }
}

enum Endpoint {
    static let defaultHost = "127.0.0.1:8765"

    /// Precedence: CLI flag, then environment, then persisted, then
    /// loopback. Environment beats persisted so an agent shell can target
    /// another server without editing the user's saved settings.
    static func resolveHost(
        flag: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        saved: @autoclosure () -> String?
    ) -> String {
        for candidate in [flag, environment["WREN_HOST"]] {
            if let candidate, !normalize(candidate).isEmpty {
                return normalize(candidate)
            }
        }
        if let stored = saved(), !normalize(stored).isEmpty {
            return normalize(stored)
        }
        return defaultHost
    }

    /// Users paste URLs; the client builds `http://<host><path>`, so strip
    /// any scheme and trailing slash rather than produce `http://http://`.
    static func normalize(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"]
        where host.lowercased().hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        while host.hasSuffix("/") { host.removeLast() }
        return host
    }
}
