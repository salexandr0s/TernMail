import Darwin
import Foundation
import TernAI

enum ClaudeCLIHelperError: String, Error, Sendable {
    case unavailable, invalidRequest, busy, cancelled, timedOut, outputLimit, invalidOutput, processFailed, accountChanged
}

enum ClaudeCLIProcessMode: Sendable {
    case capture
    case inference(schema: Bool)
    case login
}

struct ClaudeCLIInvocation: Sendable {
    let executable: URL
    let arguments: [String]
    let input: Data?
    let environment: [String: String]
    let directory: URL
    let timeout: TimeInterval
    let mode: ClaudeCLIProcessMode
}

struct ClaudeCLIProcessResult: Sendable {
    let output: Data
    let exitStatus: Int32
}

protocol ClaudeCLIProcessRunning: AnyObject, Sendable {
    func execute(_ invocation: ClaudeCLIInvocation, receive: @escaping @Sendable (Data) -> Void) async throws -> ClaudeCLIProcessResult
    func cancel()
    func writeLoginCode(_ data: Data) async throws
}

/// Process and pipe state are accessed only on queue. Dispatch sources perform
/// nonblocking reads there; no FileHandle reader can outlive cancellation.
final class ClaudeCLIProcess: ClaudeCLIProcessRunning, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.tern.mail.claude-process")
    private var process: Process?
    private var input: FileHandle?
    private var inputSource: DispatchSourceWrite?
    private var inputData = Data()
    private var inputOffset = 0
    private var sources: [DispatchSourceRead] = []
    private var handles: [FileHandle] = []
    private var ended: Set<Int> = []
    private var exitStatus: Int32?
    private var continuation: CheckedContinuation<ClaudeCLIProcessResult, any Error>?
    private var receive: (@Sendable (Data) -> Void)?
    private var mode: ClaudeCLIProcessMode = .capture
    private var failure: ClaudeCLIHelperError?
    private var cancelled = false
    private var timeout: DispatchWorkItem?
    private var output = Data()
    private var line = Data()
    private var stdoutBytes = 0
    private var stderrBytes = 0
    private var initialized = false
    private var resultLine: Data?
    private var loginURLs: Set<String> = []

    func execute(_ invocation: ClaudeCLIInvocation, receive: @escaping @Sendable (Data) -> Void) async throws -> ClaudeCLIProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                queue.async { self.start(invocation, receive: receive, reply: reply) }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.stop(.cancelled)
        }
    }

    func writeLoginCode(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard case .login = self.mode, let input = self.input, self.process?.isRunning == true,
                      self.failure == nil else { reply.resume(throwing: ClaudeCLIHelperError.invalidRequest); return }
                let count = data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
                guard count == data.count else {
                    self.stop(.processFailed)
                    reply.resume(throwing: ClaudeCLIHelperError.processFailed)
                    return
                }
                reply.resume()
            }
        }
    }

    private func start(_ invocation: ClaudeCLIInvocation, receive: @escaping @Sendable (Data) -> Void,
                       reply: CheckedContinuation<ClaudeCLIProcessResult, any Error>) {
        guard continuation == nil, process == nil, !cancelled else {
            reply.resume(throwing: cancelled ? ClaudeCLIHelperError.cancelled : .invalidRequest); return
        }
        continuation = reply; self.receive = receive; mode = invocation.mode
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = invocation.executable; child.arguments = invocation.arguments
        child.environment = invocation.environment; child.currentDirectoryURL = invocation.directory
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        input = stdin.fileHandleForWriting
        process = child
        child.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            guard let self else { return }
            self.queue.async {
                self.exitStatus = status
                self.finishIfReady()
                self.forceFinishAfterGrace()
            }
        }
        do {
            try child.run()
            try? stdin.fileHandleForReading.close()
            if let input {
                _ = fcntl(input.fileDescriptor, F_SETFL, fcntl(input.fileDescriptor, F_GETFL) | O_NONBLOCK)
                _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
            }
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            installReader(stdout.fileHandleForReading, index: 0)
            installReader(stderr.fileHandleForReading, index: 1)
            if let data = invocation.input, let input {
                installWriter(input, data: data)
            } else if case .login = invocation.mode {} else { try? input?.close(); input = nil }
            let expiry = DispatchWorkItem { [weak self] in self?.stop(.timedOut) }
            timeout = expiry
            queue.asyncAfter(deadline: .now() + invocation.timeout, execute: expiry)
        } catch {
            failure = .unavailable; exitStatus = -1; ended = [0, 1]
            finishIfReady()
        }
    }

    private func installWriter(_ handle: FileHandle, data: Data) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        inputData = data
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.failure == nil else { return }
            while self.inputOffset < self.inputData.count {
                let count = self.inputData.withUnsafeBytes { bytes in
                    Darwin.write(fd, bytes.baseAddress?.advanced(by: self.inputOffset), bytes.count - self.inputOffset)
                }
                if count > 0 { self.inputOffset += count }
                else if count < 0, errno == EINTR { continue }
                else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                else { self.stop(.processFailed); return }
            }
            self.inputSource?.cancel(); self.inputSource = nil; self.input = nil
            self.inputData.removeAll()
        }
        source.setCancelHandler { try? handle.close() }
        inputSource = source
        source.resume()
    }

    private func installReader(_ handle: FileHandle, index: Int) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        handles.append(handle)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(fd, index: index) }
        source.setCancelHandler { try? handle.close() }
        sources.append(source)
        source.resume()
    }

    private func readAvailable(_ fd: Int32, index: Int) {
        guard !ended.contains(index) else { return }
        var bytes = [UInt8](repeating: 0, count: 8_192)
        for _ in 0..<64 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { consume(Data(bytes.prefix(count)), index: index) }
            else if count == 0 {
                ended.insert(index)
                if index == 0, !line.isEmpty, case .inference = mode { stop(.invalidOutput) }
                finishIfReady(); return
            } else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno == EINTR { continue }
            else { ended.insert(index); stop(.processFailed); finishIfReady(); return }
        }
    }

    private func consume(_ data: Data, index: Int) {
        guard failure == nil else { return }
        if index == 1 {
            stderrBytes += data.count
            guard stderrBytes <= 131_072 else { stop(.outputLimit); return }
            if case .login = mode { loginOutput(data) }
            return
        }
        stdoutBytes += data.count
        guard stdoutBytes <= 4_194_304 else { stop(.outputLimit); return }
        switch mode {
        case .capture:
            guard output.count + data.count <= 65_536 else { stop(.outputLimit); return }
            output.append(data)
        case .login: loginOutput(data)
        case .inference:
            for byte in data {
                if byte == 10 {
                    if !line.isEmpty { consumeLine(line) }
                    line.removeAll(keepingCapacity: true)
                } else {
                    guard line.count < 1_048_576 else { stop(.outputLimit); return }
                    line.append(byte)
                }
                if failure != nil { return }
            }
        }
    }

    private func consumeLine(_ data: Data) {
        guard let value = try? AIJSON.decode(data), let type = value["type"]?.stringValue,
              resultLine == nil else { stop(.invalidOutput); return }
        if type == "system", value["subtype"] == .string("init") {
            guard !initialized, validInitialization(value) else { stop(.invalidOutput); return }
            initialized = true
            let fields = ["type", "subtype", "tools", "mcp_servers", "plugins", "skills"]
            if let sanitized = try? AIJSON.object(Dictionary(uniqueKeysWithValues: fields.compactMap { key in
                value[key].map { (key, $0) }
            })).encoded() { receive?(sanitized) }
            return
        }
        guard initialized else { stop(.invalidOutput); return }
        if type == "result" {
            guard value["subtype"] == .string("success"), value["is_error"] == .bool(false) else { stop(.processFailed); return }
            resultLine = data
        } else if type == "stream_event" || type == "assistant" { receive?(data) }
    }

    private func validInitialization(_ value: AIJSON) -> Bool {
        guard case .inference(let schema) = mode, let tools = value["tools"]?.arrayValue,
              tools.allSatisfy({ schema && $0 == .string("StructuredOutput") }), tools.count <= 1 else { return false }
        return ["mcp_servers", "plugins", "skills"].allSatisfy { value[$0]?.arrayValue?.isEmpty == true }
    }

    private func loginOutput(_ data: Data) {
        guard output.count + data.count <= 131_072 else { stop(.outputLimit); return }
        output.append(data)
        let text = String(decoding: output, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"https://[^\s\u001B]+(?=[\s\u001B])"#) else { return }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])),
                  ["claude.ai", "console.anthropic.com", "platform.claude.com"].contains(url.host),
                  url.path == "/oauth/authorize", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                  url.absoluteString.utf8.count <= 16_384, loginURLs.insert(url.absoluteString).inserted,
                  let event = try? AIJSON.object(["type": .string("auth_url"), "url": .string(url.absoluteString)]).encoded() else { continue }
            receive?(event)
        }
    }

    private func stop(_ error: ClaudeCLIHelperError) {
        if failure == nil { failure = error }
        closeInput()
        if let process, process.isRunning { process.terminate() }
        finishIfReady()
        forceFinishAfterGrace()
    }

    private func forceFinishAfterGrace() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.continuation != nil else { return }
            if let process = self.process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            if self.failure == nil { self.failure = .invalidOutput }
            self.ended = [0, 1]
            if self.exitStatus == nil { self.exitStatus = -1 }
            self.finishIfReady()
        }
    }

    private func closeInput() {
        if let inputSource { inputSource.cancel(); self.inputSource = nil }
        else { try? input?.close() }
        input = nil; inputData.removeAll()
    }

    private func finishIfReady() {
        guard let status = exitStatus, ended.count == 2, let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        sources.forEach { $0.cancel() }; sources.removeAll(); handles.removeAll()
        closeInput()
        if let failure { continuation.resume(throwing: failure) }
        else if case .inference = mode {
            if status == 0, initialized, let resultLine {
                receive?(resultLine)
                continuation.resume(returning: ClaudeCLIProcessResult(output: Data(), exitStatus: status))
            } else { continuation.resume(throwing: ClaudeCLIHelperError.processFailed) }
        } else { continuation.resume(returning: ClaudeCLIProcessResult(output: output, exitStatus: status)) }
        receive = nil; process?.terminationHandler = nil; process = nil
    }
}
