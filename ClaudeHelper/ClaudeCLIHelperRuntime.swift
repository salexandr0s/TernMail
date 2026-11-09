import CryptoKit
import Foundation
import TernAI

actor ClaudeCLIHelperRuntime {
    private struct Key: Hashable { let owner: UUID; let id: String }
    private struct Job {
        var process: (any ClaudeCLIProcessRunning)?
        var cancelled = false
        var login = false
    }
    static let shared = ClaudeCLIHelperRuntime()
    private let locate: @Sendable () -> URL?
    private let makeProcess: @Sendable () -> any ClaudeCLIProcessRunning
    private var jobs: [Key: Job] = [:]
    private var invalidatedOwners: Set<UUID> = []
    private var earlyCancellations: [Key] = []

    init(locate: @escaping @Sendable () -> URL? = ClaudeCLIExecutable.locate,
         makeProcess: @escaping @Sendable () -> any ClaudeCLIProcessRunning = { ClaudeCLIProcess() }) {
        self.locate = locate; self.makeProcess = makeProcess
    }

    static let isolationArguments = ["--safe-mode", "--setting-sources", "", "--settings",
        #"{"disableAllHooks":true,"enabledPlugins":{}}"#, "--disable-slash-commands", "--tools", "",
        "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--no-chrome"]

    /// `requestID` lets the app cancel a check it no longer needs, which frees its job slot.
    func status(owner: UUID, requestID: String) async -> ClaudeCLIStatus {
        guard let executable = locate() else { return ClaudeCLIStatus(available: false) }
        let key = Key(owner: owner, id: requestID)
        do {
            try reserve(key)
            defer { jobs.removeValue(forKey: key) }
            let versionResult = try await launch(key, executable: executable, arguments: ["--version"], mode: .capture)
            let version = Self.version(versionResult.output)
            return try await status(key, executable: executable, version: version)
        } catch {
            return ClaudeCLIStatus(available: true, errorCode: (error as? ClaudeCLIHelperError)?.rawValue ?? "processFailed")
        }
    }

    func login(owner: UUID, requestID: String, receive: @escaping @Sendable (Data) -> Void) async throws {
        guard let executable = locate() else { throw ClaudeCLIHelperError.unavailable }
        let key = Key(owner: owner, id: requestID)
        guard !jobs.values.contains(where: \.login) else { throw ClaudeCLIHelperError.busy }
        try reserve(key, login: true)
        defer { jobs.removeValue(forKey: key) }
        let result = try await launch(key, executable: executable, arguments: Self.isolationArguments + ["auth", "login", "--claudeai"],
                                      mode: .login, timeout: 600, receive: receive)
        guard result.exitStatus == 0 else { throw ClaudeCLIHelperError.processFailed }
    }

    func submitLoginCode(owner: UUID, requestID: String, code: String) async throws {
        let key = Key(owner: owner, id: requestID)
        guard let job = jobs[key], job.login, !job.cancelled, let process = job.process,
              !code.isEmpty, code.utf8.count <= 4_096,
              code.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw ClaudeCLIHelperError.invalidRequest }
        try await process.writeLoginCode(Data((code + "\n").utf8))
    }

    func run(owner: UUID, requestID: String, data: Data, receive: @escaping @Sendable (Data) -> Void) async throws {
        guard data.count <= 786_432,
              let envelope = try? JSONDecoder().decode(ClaudeCLIHelperRunRequest.self, from: data),
              envelope.request.count <= 524_288,
              let request = try? JSONDecoder().decode(ClaudeCLIRequest.self, from: envelope.request),
              request.systemPrompt == ClaudeCLIRequest.framingInstructions, !request.containsAtSign,
              ["default", "sonnet", "opus", "haiku"].contains(request.model),
              envelope.expectedAccountFingerprint.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil,
              request.message["type"] == .string("user"),
              request.message["message"]?["role"] == .string("user") else { throw ClaudeCLIHelperError.invalidRequest }
        guard let executable = locate() else { throw ClaudeCLIHelperError.unavailable }
        let key = Key(owner: owner, id: requestID)
        try reserve(key)
        defer { jobs.removeValue(forKey: key) }
        try Self.check(try await status(key, executable: executable), envelope: envelope)
        var arguments = Self.isolationArguments + ["--print", "--no-session-persistence", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--input-format", "stream-json", "--system-prompt", request.systemPrompt]
        if request.model != "default" { arguments += ["--model", request.model] }
        if let schema = request.outputSchema {
            guard schema.objectValue != nil else { throw ClaudeCLIHelperError.invalidRequest }
            let encoded = try schema.jsonString()
            guard encoded.utf8.count <= 65_536 else { throw ClaudeCLIHelperError.invalidRequest }
            arguments += ["--json-schema", encoded]
        }
        var input = try request.message.encoded()
        guard input.count <= 524_288 else { throw ClaudeCLIHelperError.invalidRequest }
        input.append(10)
        _ = try await launch(key, executable: executable, arguments: arguments, input: input,
                             mode: .inference(schema: request.outputSchema != nil), timeout: 180, receive: receive)
        try Self.check(try await status(key, executable: executable), envelope: envelope)
    }

    func cancel(owner: UUID, requestID: String) {
        let key = Key(owner: owner, id: requestID)
        if jobs[key] != nil { jobs[key]?.cancelled = true; jobs[key]?.process?.cancel() }
        else {
            earlyCancellations.append(key)
            if earlyCancellations.count > 256 { earlyCancellations.removeFirst() }
        }
    }

    func disconnect(owner: UUID) {
        invalidatedOwners.insert(owner)
        for key in jobs.keys where key.owner == owner { jobs[key]?.cancelled = true; jobs[key]?.process?.cancel() }
    }

    private func reserve(_ key: Key, login: Bool = false) throws {
        guard UUID(uuidString: key.id) != nil else { throw ClaudeCLIHelperError.invalidRequest }
        guard !invalidatedOwners.contains(key.owner), !earlyCancellations.contains(key), !Task.isCancelled else {
            throw ClaudeCLIHelperError.cancelled
        }
        guard jobs[key] == nil, jobs.count < 4, invalidatedOwners.count < 1_024 else { throw ClaudeCLIHelperError.busy }
        jobs[key] = Job(login: login)
    }

    private func launch(_ key: Key, executable: URL, arguments: [String], input: Data? = nil,
                        mode: ClaudeCLIProcessMode, timeout: TimeInterval = 20,
                        receive: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> ClaudeCLIProcessResult {
        guard let job = jobs[key], !job.cancelled, !Task.isCancelled else { throw ClaudeCLIHelperError.cancelled }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-claude-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = makeProcess()
        jobs[key]?.process = process
        defer { jobs[key]?.process = nil }
        let invocation = ClaudeCLIInvocation(executable: executable, arguments: arguments, input: input,
            environment: ClaudeCLIExecutable.environment(directory: directory), directory: directory, timeout: timeout, mode: mode)
        let result = try await process.execute(invocation, receive: receive)
        guard jobs[key]?.cancelled == false, !Task.isCancelled else { throw ClaudeCLIHelperError.cancelled }
        return result
    }

    private func status(_ key: Key, executable: URL, version: String? = nil) async throws -> ClaudeCLIStatus {
        let result = try await launch(key, executable: executable, arguments: Self.isolationArguments + ["auth", "status", "--json"], mode: .capture)
        guard let value = try? AIJSON.decode(result.output), let loggedIn = value["loggedIn"]?.boolValue else {
            throw ClaudeCLIHelperError.invalidOutput
        }
        let method = Self.safeLabel(value["authMethod"]?.stringValue)
        let subscription = Self.safeLabel(value["subscriptionType"]?.stringValue)
        let provider = Self.safeLabel(value["apiProvider"]?.stringValue)
        let identity = ["email", "orgId", "accountId", "userId"].compactMap { field -> String? in
            guard let text = value[field]?.stringValue, !text.isEmpty, text.utf8.count <= 512 else { return nil }
            return field + ":" + text.lowercased()
        }
        let fingerprint: String?
        if loggedIn, !identity.isEmpty, let method {
            let content = ([method, provider ?? "", subscription ?? ""] + identity).joined(separator: "\u{0}")
            fingerprint = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        } else { fingerprint = nil }
        return ClaudeCLIStatus(available: true, version: version, loggedIn: loggedIn && result.exitStatus == 0,
                               authMethod: method, subscriptionType: subscription, accountFingerprint: fingerprint)
    }

    private static func check(_ status: ClaudeCLIStatus, envelope: ClaudeCLIHelperRunRequest) throws {
        guard status.loggedIn, status.accountFingerprint == envelope.expectedAccountFingerprint,
              status.authMethod == envelope.expectedAuthMethod,
              status.subscriptionType == envelope.expectedSubscriptionType else { throw ClaudeCLIHelperError.accountChanged }
    }

    private static func version(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first.map(String.init),
              value.utf8.count <= 64, value.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:[-.A-Za-z0-9]+)?\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func safeLabel(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 64,
              value.range(of: #"\A[A-Za-z0-9_.-]+\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}
