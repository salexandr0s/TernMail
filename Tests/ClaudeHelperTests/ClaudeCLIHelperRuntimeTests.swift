import Foundation
import Synchronization
import Testing
import TernAI

@Suite struct ClaudeCLIHelperRuntimeTests {
    @Test func mailUsesStdinWithFixedIsolationFlagsAndPrivateTemporaryDirectory() async throws {
        let process = RecordingClaudeProcess()
        let runtime = ClaudeCLIHelperRuntime(locate: { URL(fileURLWithPath: "/test/claude") }, makeProcess: { process })
        let owner = UUID()
        let status = await runtime.status(owner: owner, requestID: UUID().uuidString)
        let envelope = try request(status: status)
        try await runtime.run(owner: owner, requestID: UUID().uuidString, data: envelope) { _ in }
        let calls = process.calls.withLock { $0 }
        let inference = try #require(calls.first { $0.arguments.contains("--print") })
        #expect(inference.arguments.contains("--safe-mode"))
        #expect(inference.arguments.contains("--disable-slash-commands"))
        #expect(inference.arguments.contains("--no-session-persistence"))
        #expect(inference.arguments.contains(#"{"disableAllHooks":true,"enabledPlugins":{}}"#))
        #expect(!inference.arguments.contains { $0.contains("PRIVATE_CONTEXT_CANARY") })
        #expect(String(data: try #require(inference.input), encoding: .utf8)?.contains("PRIVATE_CONTEXT_CANARY") == true)
        #expect(inference.environment["HOME"] == ClaudeCLIExecutable.userHome)
        #expect(inference.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(inference.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(inference.environment["NODE_OPTIONS"] == nil)
        #expect(calls.allSatisfy { !FileManager.default.fileExists(atPath: $0.directory.path) })
    }

    @Test func accountChangeStopsInferenceBeforeMailIsSent() async throws {
        let process = RecordingClaudeProcess()
        let runtime = ClaudeCLIHelperRuntime(locate: { URL(fileURLWithPath: "/test/claude") }, makeProcess: { process })
        let owner = UUID()
        let status = await runtime.status(owner: owner, requestID: UUID().uuidString)
        process.identity.withLock { $0 = "replacement@example.invalid" }
        let envelope = try request(status: status)
        await #expect(throws: ClaudeCLIHelperError.accountChanged) {
            try await runtime.run(owner: owner, requestID: UUID().uuidString, data: envelope) { _ in }
        }
        #expect(!process.calls.withLock { $0 }.contains { $0.arguments.contains("--print") })
    }

    @Test func cancellationAndDisconnectCannotBeLostBeforeRunStarts() async throws {
        let process = RecordingClaudeProcess()
        let runtime = ClaudeCLIHelperRuntime(locate: { URL(fileURLWithPath: "/test/claude") }, makeProcess: { process })
        let owner = UUID(), id = UUID().uuidString
        let status = await runtime.status(owner: owner, requestID: UUID().uuidString)
        let envelope = try request(status: status)
        await runtime.cancel(owner: owner, requestID: id)
        await #expect(throws: ClaudeCLIHelperError.cancelled) {
            try await runtime.run(owner: owner, requestID: id, data: envelope) { _ in }
        }
        await runtime.disconnect(owner: owner)
        await #expect(throws: ClaudeCLIHelperError.cancelled) {
            try await runtime.run(owner: owner, requestID: UUID().uuidString, data: envelope) { _ in }
        }
        #expect(!process.calls.withLock { $0 }.contains { $0.arguments.contains("--print") })
    }

    @Test func statusContainsFingerprintWithoutRawIdentity() async throws {
        let process = RecordingClaudeProcess()
        let runtime = ClaudeCLIHelperRuntime(locate: { URL(fileURLWithPath: "/test/claude") }, makeProcess: { process })
        let status = await runtime.status(owner: UUID(), requestID: UUID().uuidString)
        #expect(status.loggedIn)
        #expect(status.accountFingerprint?.count == 64)
        let encoded = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(!encoded.contains("person@example.invalid"))
        #expect(!encoded.contains("org-private"))
    }

    @Test func cancelIsScopedToTheCallingConnection() async throws {
        let process = RecordingClaudeProcess()
        let runtime = ClaudeCLIHelperRuntime(locate: { URL(fileURLWithPath: "/test/claude") }, makeProcess: { process })
        let owner = UUID(), otherOwner = UUID(), id = UUID().uuidString
        let status = await runtime.status(owner: owner, requestID: UUID().uuidString)
        await runtime.cancel(owner: otherOwner, requestID: id)
        try await runtime.run(owner: owner, requestID: id, data: request(status: status)) { _ in }
        #expect(process.calls.withLock { $0 }.contains { $0.arguments.contains("--print") })
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAStatusCheckStopsItAndFreesItsJobSlot() async throws {
        let started = AsyncStream<Void>.makeStream()
        let holds = Mutex(true)
        let runtime = ClaudeCLIHelperRuntime(locate: { URL(fileURLWithPath: "/test/claude") }, makeProcess: {
            if holds.withLock({ $0 }) { return HeldClaudeProcess(started: started.continuation) }
            return RecordingClaudeProcess()
        })
        let owner = UUID()
        let ids = (0..<4).map { _ in UUID().uuidString }
        let checks = ids.map { id in Task { await runtime.status(owner: owner, requestID: id) } }
        var arrivals = started.stream.makeAsyncIterator()
        for _ in ids { _ = await arrivals.next() }
        holds.withLock { $0 = false }
        #expect(await runtime.status(owner: owner, requestID: UUID().uuidString).errorCode == "busy")
        for id in ids { await runtime.cancel(owner: owner, requestID: id) }
        for check in checks { #expect(await check.value.errorCode == "cancelled") }
        #expect(await runtime.status(owner: owner, requestID: UUID().uuidString).loggedIn)
    }

    @Test(arguments: ["prompt", "model"])
    func arbitraryPromptOrModelCannotReachProcess(field: String) async throws {
        let process = RecordingClaudeProcess()
        let runtime = ClaudeCLIHelperRuntime(locate: { URL(fileURLWithPath: "/test/claude") }, makeProcess: { process })
        let status = ClaudeCLIStatus(available: true, accountFingerprint: String(repeating: "a", count: 64))
        let data = try request(status: status, model: field == "model" ? "--dangerously-skip-permissions" : "default",
                               prompt: field == "prompt" ? "Private mail in argv" : ClaudeCLIRequest.framingInstructions)
        await #expect(throws: ClaudeCLIHelperError.invalidRequest) {
            try await runtime.run(owner: UUID(), requestID: UUID().uuidString, data: data) { _ in }
        }
        #expect(process.calls.withLock { $0.isEmpty })
    }

    @Test(arguments: ["text", "text_part", "json_escape", "combining_mark", "schema"])
    func literalAtSignCannotReachProcess(location: String) async throws {
        let process = RecordingClaudeProcess()
        let runtime = ClaudeCLIHelperRuntime(locate: { URL(fileURLWithPath: "/test/claude") }, makeProcess: { process })
        let status = ClaudeCLIStatus(available: true, accountFingerprint: String(repeating: "a", count: 64))
        let data: Data
        switch location {
        case "text": data = try request(status: status, content: .string("Summarize @/etc/hosts"))
        case "text_part":
            data = try request(status: status, content: .array([.object(["type": .string("text"), "text": .string("From pat@example.invalid")])]))
        case "json_escape":
            // Decoding turns the escape back into the character before any process would read it.
            let plain = try JSONDecoder().decode(ClaudeCLIHelperRunRequest.self,
                from: request(status: status, content: .string("Summarize AT_SIGN/etc/hosts")))
            let escaped = String(decoding: plain.request, as: UTF8.self).replacingOccurrences(of: "AT_SIGN", with: "\\u0040")
            data = try envelope(Data(escaped.utf8), status: status)
        case "combining_mark": data = try request(status: status, content: .string("Summarize @\u{301}/etc/hosts"))
        default: data = try request(status: status, schema: .object(["type": .string("object"), "description": .string("@/etc/hosts")]))
        }
        await #expect(throws: ClaudeCLIHelperError.invalidRequest) {
            try await runtime.run(owner: UUID(), requestID: UUID().uuidString, data: data) { _ in }
        }
        #expect(process.calls.withLock { $0.isEmpty })
    }

    @Test func mailTextReachesProcessWithEscapedAtSigns() async throws {
        let mail = "From pat@example.invalid: see @/Users/person/.ssh/id_ed25519"
        let captured = Mutex<ClaudeCLIRequest?>(nil)
        let provider = ClaudeCLIProvider(transport: ClaudeCLITransport { request in
            captured.withLock { $0 = request }
            return AsyncThrowingStream { continuation in
                continuation.yield(Data(#"{"type":"result","subtype":"success","is_error":false,"result":"OK"}"#.utf8))
                continuation.finish()
            }
        })
        for try await _ in provider.respond(AIRequest(model: "default", input: [.object(["role": .string("user"), "content": .string(mail)])],
                                                      instructions: "The mailbox is me@example.invalid.")) {}
        let process = RecordingClaudeProcess()
        let runtime = ClaudeCLIHelperRuntime(locate: { URL(fileURLWithPath: "/test/claude") }, makeProcess: { process })
        let owner = UUID()
        let status = await runtime.status(owner: owner, requestID: UUID().uuidString)
        let data = try envelope(JSONEncoder().encode(try #require(captured.withLock { $0 })), status: status)
        try await runtime.run(owner: owner, requestID: UUID().uuidString, data: data) { _ in }
        let inference = try #require(process.calls.withLock { $0 }.first { $0.arguments.contains("--print") })
        let input = try #require(inference.input)
        #expect(!input.contains(UInt8(ascii: "@")))
        #expect(!inference.arguments.contains { $0.utf8.contains(UInt8(ascii: "@")) })
        // The CLI decodes the stdin line, so the text it scans still spells the escape.
        let text = try #require(AIJSON.decode(input)["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(!text.utf8.contains(UInt8(ascii: "@")))
        let envelope = try AIJSON.decode(Data(text.utf8))
        #expect(envelope["application_instructions"] == .string("The mailbox is me@example.invalid."))
        #expect(envelope["conversation_history"]?.arrayValue?.first?["content"] == .string(mail))
    }

    @Test(arguments: [false, true])
    func actualProcessAcceptsOnlyDisabledCustomizationRegistry(unsafe: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialization: AIJSON = .object(["type": .string("system"), "subtype": .string("init"),
            "tools": .array(unsafe ? [.string("Bash")] : []), "mcp_servers": .array([]), "plugins": .array([]), "skills": .array([])])
        let result: AIJSON = .object(["type": .string("result"), "subtype": .string("success"), "is_error": .bool(false), "result": .string("OK")])
        let text = try initialization.jsonString() + "\n" + result.jsonString() + "\n"
        let invocation = ClaudeCLIInvocation(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", text], input: nil,
            environment: ClaudeCLIExecutable.environment(directory: directory), directory: directory, timeout: 5, mode: .inference(schema: false))
        let lines = Mutex<[Data]>([])
        let child = ClaudeCLIProcess()
        if unsafe {
            await #expect(throws: ClaudeCLIHelperError.invalidOutput) {
                try await child.execute(invocation) { line in lines.withLock { $0.append(line) } }
            }
            #expect(lines.withLock { $0.isEmpty })
        } else {
            let response = try await child.execute(invocation) { line in lines.withLock { $0.append(line) } }
            #expect(response.exitStatus == 0)
            #expect(lines.withLock { $0.count } == 2)
        }
    }

    @Test func cancellingActualProcessTerminatesIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = ClaudeCLIProcess()
        let initialization = #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"plugins":[],"skills":[]}"# + "\n"
        let invocation = ClaudeCLIInvocation(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: Self.announceThenWait(initialization), input: nil,
            environment: ClaudeCLIExecutable.environment(directory: directory), directory: directory, timeout: 10,
            mode: .inference(schema: false))
        // The helper reports the child's first line, so cancel can't land before the child starts.
        let task = try #require(await start(invocation, on: child))
        child.cancel()
        await #expect(throws: ClaudeCLIHelperError.cancelled) { try await task.value }
    }

    @Test func inheritedOutputPipeCannotKeepAJobAliveAfterItsParentExits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = ClaudeCLIProcess()
        // The descendant exits shortly afterward; it never runs a shell or reads user data.
        let script = "import os,time\nif os.fork() == 0: time.sleep(3)\nos._exit(0)\n"
        let invocation = ClaudeCLIInvocation(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], input: nil,
            environment: ClaudeCLIExecutable.environment(directory: directory), directory: directory, timeout: 0.1, mode: .capture)
        let start = ContinuousClock.now
        await #expect(throws: ClaudeCLIHelperError.timedOut) { try await child.execute(invocation) { _ in } }
        #expect(start.duration(to: .now) < .seconds(3))
    }

    @Test func aFullLoginPipeDoesNotBlockCancellation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = ClaudeCLIProcess()
        // The child prints a sign-in link, which the helper reports, and never reads its input.
        let invocation = ClaudeCLIInvocation(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: Self.announceThenWait("https://claude.ai/oauth/authorize?state=test\n"), input: nil,
            environment: ClaudeCLIExecutable.environment(directory: directory), directory: directory, timeout: 5, mode: .login)
        // A write before the child runs fails at once, so the pipe would never fill.
        let task = try #require(await start(invocation, on: child))
        for _ in 0..<64 {
            do { try await child.writeLoginCode(Data(repeating: 65, count: 4_097)) }
            catch { break }
        }
        child.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func successfulResultIsNotForwardedWhenTheProcessFails() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"plugins":[],"skills":[]}"# + "\n"
            + #"{"type":"result","subtype":"success","is_error":false,"result":"OK"}"# + "\n"
        let invocation = ClaudeCLIInvocation(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys;sys.stdout.write(sys.argv[1]);sys.exit(2)", text], input: nil,
            environment: ClaudeCLIExecutable.environment(directory: directory), directory: directory, timeout: 5, mode: .inference(schema: false))
        let lines = Mutex<[Data]>([])
        await #expect(throws: ClaudeCLIHelperError.processFailed) {
            try await ClaudeCLIProcess().execute(invocation) { line in lines.withLock { $0.append(line) } }
        }
        #expect(lines.withLock { $0.count } == 1)
        #expect(try AIJSON.decode(try #require(lines.withLock { $0.first }))["type"] == .string("system"))
    }

    private func request(status: ClaudeCLIStatus, model: String = "default", prompt: String = ClaudeCLIRequest.framingInstructions,
                         content: AIJSON = .string("PRIVATE_CONTEXT_CANARY"), schema: AIJSON? = nil) throws -> Data {
        let request = ClaudeCLIRequest(model: model, systemPrompt: prompt,
            message: .object(["type": .string("user"), "message": .object(["role": .string("user"), "content": content])]),
            outputSchema: schema)
        return try envelope(JSONEncoder().encode(request), status: status)
    }

    private func envelope(_ request: Data, status: ClaudeCLIStatus) throws -> Data {
        try JSONEncoder().encode(ClaudeCLIHelperRunRequest(request: request,
            expectedAccountFingerprint: status.accountFingerprint ?? "", expectedAuthMethod: status.authMethod,
            expectedSubscriptionType: status.subscriptionType))
    }

    /// Arguments that make /bin/sh write `line` to stdout, then wait far longer than any test runs.
    private static func announceThenWait(_ line: String) -> [String] {
        ["-c", #"printf %s "$1"; exec /bin/sleep 30"#, "sh", line]
    }

    /// Starts `invocation` and returns its task once the helper reports the child's
    /// first output, or nil if the child ended without any.
    private func start(_ invocation: ClaudeCLIInvocation, on child: ClaudeCLIProcess) async -> Task<ClaudeCLIProcessResult, any Error>? {
        let (reports, report) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            defer { report.finish() }
            return try await child.execute(invocation) { _ in report.yield() }
        }
        return await reports.first { _ in true } == nil ? nil : task
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-helper-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private final class RecordingClaudeProcess: ClaudeCLIProcessRunning, Sendable {
    let calls = Mutex<[ClaudeCLIInvocation]>([])
    let identity = Mutex("person@example.invalid")

    func execute(_ invocation: ClaudeCLIInvocation, receive: @escaping @Sendable (Data) -> Void) async throws -> ClaudeCLIProcessResult {
        calls.withLock { $0.append(invocation) }
        #expect(FileManager.default.fileExists(atPath: invocation.directory.path))
        if invocation.arguments == ["--version"] { return ClaudeCLIProcessResult(output: Data("2.1.384 (Claude Code)\n".utf8), exitStatus: 0) }
        if invocation.arguments.contains("status") {
            let value: AIJSON = .object(["loggedIn": .bool(true), "authMethod": .string("claude.ai"), "apiProvider": .string("firstParty"),
                "email": .string(identity.withLock { $0 }), "orgId": .string("org-private"), "subscriptionType": .string("max")])
            return ClaudeCLIProcessResult(output: try value.encoded(), exitStatus: 0)
        }
        return ClaudeCLIProcessResult(output: Data(), exitStatus: 0)
    }
    func cancel() {}
    func writeLoginCode(_ data: Data) async throws {}
}

/// A CLI that never answers until its job is cancelled.
private final class HeldClaudeProcess: ClaudeCLIProcessRunning, Sendable {
    private let started: AsyncStream<Void>.Continuation
    private let state = Mutex<(cancelled: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    init(started: AsyncStream<Void>.Continuation) { self.started = started }

    func execute(_ invocation: ClaudeCLIInvocation, receive: @escaping @Sendable (Data) -> Void) async throws -> ClaudeCLIProcessResult {
        await withCheckedContinuation { continuation in
            let cancelled = state.withLock { state in
                if !state.cancelled { state.waiter = continuation }
                return state.cancelled
            }
            if cancelled { continuation.resume() }
            started.yield(())
        }
        throw ClaudeCLIHelperError.cancelled
    }
    func cancel() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.cancelled = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
    func writeLoginCode(_ data: Data) async throws {}
}

@Suite struct ClaudeCLICallerValidationTests {
    @Test(arguments: ["dev.tern.mail", "dev.tern.mail.testing"])
    func appBundleIDsAreAcceptedAsTheHost(identifier: String) {
        #expect(ClaudeCLICallerValidation.hostIdentifier(in: ["TernHostBundleIdentifier": identifier]) == identifier)
    }

    @Test(arguments: [nil, "", #"dev.tern.mail" or identifier "dev.tern.other"#, "dev.tern mail", "dev.tern.mail\\", "dev.tern.mail\n"] as [String?])
    func missingOrUnsafeHostIdentifiersFailClosed(value: String?) {
        let info: [String: Any] = value.map { ["TernHostBundleIdentifier": $0] } ?? [:]
        #expect(ClaudeCLICallerValidation.hostIdentifier(in: info) == nil)
    }

    @Test func productionHostRequirementTextIsPinned() throws {
        let host = try #require(ClaudeCLICallerValidation.hostIdentifier(in: ["TernHostBundleIdentifier": "dev.tern.mail"]))
        #expect(ClaudeCLICallerValidation.teamRequirement(host: host, team: "ABCDE12345")
            == #"identifier "dev.tern.mail" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
        #if DEBUG
        #expect(ClaudeCLICallerValidation.adHocRequirement(host: host, cdhash: "00112233445566778899aabbccddeeff00112233")
            == #"identifier "dev.tern.mail" and cdhash H"00112233445566778899aabbccddeeff00112233""#)
        #endif
    }
}
