import Darwin
import Foundation
import Security

enum ClaudeCLIExecutable {
    static let userHome: String = {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: directory)
    }()

    static func locate() -> URL? {
        let candidates = [userHome + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.lazy.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }.first(where: valid)
    }

    private static func valid(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let identity = "anchor apple generic and identifier \"com.anthropic.claude-code\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func environment(directory: URL) -> [String: String] {
        ["HOME": userHome, "USER": NSUserName(), "LOGNAME": NSUserName(),
         "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "TMPDIR": directory.path + "/", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
         "TERM": "dumb", "NO_COLOR": "1", "DISABLE_AUTOUPDATER": "1",
         "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]
    }
}
