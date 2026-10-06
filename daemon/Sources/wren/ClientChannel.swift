import Foundation

/// This Mac's channel name on the server: `mac-<sanitized hostname>`.
enum ClientChannel {
    static let prefix = "mac-"
    /// Contract channel regex is `[a-z0-9_-]{1,32}`.
    static let maxLength = 32
    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    static func defaultChannel(
        hostname: String = currentHostname()
    ) -> String {
        // "studio.local" and "studio.tail1234.ts.net" are the same Mac.
        let short = hostname.split(separator: ".").first.map(String.init)
            ?? hostname
        let body = String(sanitize(short).prefix(maxLength - prefix.count))
        return prefix + (body.isEmpty ? "unknown" : body)
    }

    /// Lowercases, maps whitespace to "-", drops everything else outside
    /// the contract alphabet (apostrophes in "Che's MacBook", accents).
    static func sanitize(_ input: String) -> String {
        var result = ""
        for scalar in input.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespaces.contains(scalar) {
                result.append("-")
            }
        }
        return result
    }

    /// The POSIX hostname (what `hostname` prints, and what ssh prompts
    /// show), so `mac-<host>` is recognizable. gethostname is a local
    /// syscall; ProcessInfo.hostName can block on reverse DNS.
    static func currentHostname() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else {
            return Host.current().localizedName ?? "mac"
        }
        let name = String(cString: buffer)
        return name.isEmpty ? (Host.current().localizedName ?? "mac") : name
    }
}
