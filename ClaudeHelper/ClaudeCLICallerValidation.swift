import Foundation
import Security

/// Bundled service peers are verified by the XPC audit identity, never by PID.
enum ClaudeCLICallerValidation {
    static func requirement() -> String? {
        guard let host = hostIdentifier(in: Bundle.main.infoDictionary) else { return nil }
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else { return nil }
        var ownStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode else { return nil }
        var ownInformation: CFDictionary?
        guard SecCodeCopySigningInformation(ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &ownInformation) == errSecSuccess,
              let information = ownInformation as? [String: Any] else { return nil }
        if let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
           !team.isEmpty, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) {
            return validated(teamRequirement(host: host, team: team))
        }
        #if DEBUG
        // Ad-hoc development builds have no Team ID. Bind this service to the
        // exact signed executable in its enclosing app, not an identifier alone.
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard hostURL.pathExtension == "app" else { return nil }
        var hostCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(hostURL as CFURL, [], &hostCode) == errSecSuccess, let hostCode,
              SecStaticCodeCheckValidity(hostCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return nil
        }
        var hostInformation: CFDictionary?
        guard SecCodeCopySigningInformation(hostCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &hostInformation) == errSecSuccess,
              let hostInfo = hostInformation as? [String: Any],
              hostInfo[kSecCodeInfoIdentifier as String] as? String == host,
              let hash = hostInfo[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { return nil }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return validated(adHocRequirement(host: host, cdhash: hex))
        #else
        return nil
        #endif
    }

    /// The host app's bundle ID from `TernHostBundleIdentifier` in this service's
    /// Info.plist. It must use only the ASCII letters, digits, dots and hyphens a
    /// bundle ID allows, so it cannot end the quoted identifier in a requirement.
    static func hostIdentifier(in info: [String: Any]?) -> String? {
        guard let identifier = info?["TernHostBundleIdentifier"] as? String,
              identifier.range(of: #"\A[A-Za-z0-9.-]+\z"#, options: .regularExpression) != nil else { return nil }
        return identifier
    }

    static func teamRequirement(host: String, team: String) -> String {
        "identifier \"\(host)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    #if DEBUG
    static func adHocRequirement(host: String, cdhash: String) -> String {
        "identifier \"\(host)\" and cdhash H\"\(cdhash)\""
    }
    #endif

    private static func validated(_ text: String) -> String? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              requirement != nil else { return nil }
        return text
    }
}
