import Foundation
import MailStore
import Observation
import TernAI

/// Owns only suggestions and chat history. ComposeModel remains the draft's writer.
@MainActor @Observable
final class ComposeAssistantModel {
    var prompt = ""
    private(set) var messages: [AssistantMessage] = []
    private(set) var proposal: ComposeAssistantProposal?
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private(set) var statusText: String?

    private let compose: ComposeModel
    private let assistant: AssistantModel
    @ObservationIgnored private var session: ComposeAssistantSession?
    @ObservationIgnored private var history: [AIJSON] = []
    @ObservationIgnored private var proposalContext: ComposeAssistantContext?
    @ObservationIgnored private var previousSuggestion: ComposeAssistantProposal?
    @ObservationIgnored private var undoContext: (before: ComposeAssistantContext, after: ComposeAssistantContext)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var turnID: UUID?
    @ObservationIgnored private var lastRequest: String?

    init(compose: ComposeModel, assistant: AssistantModel) {
        self.compose = compose; self.assistant = assistant
    }

    var availabilityMessage: String? {
        guard compose.isEditable, let accountID = compose.draft?.accountID else { return "Open an editable draft to use the assistant." }
        return assistant.composeAvailabilityMessage(accountID: accountID)
    }
    var contextDescription: String {
        "This draft · \(compose.fromEmail) · \(assistant.hasCalendarAccess ? "Allowed calendars" : "Calendar access off")"
    }
    var preservesInlineImages: Bool { proposalContext?.hasInlineImages == true }
    var proposalStatusMessage: String? {
        guard proposal != nil, !isRunning, proposalContext != ComposeAssistantContext(compose) else { return nil }
        return "The draft changed. Ask for an updated suggestion before applying it."
    }
    var canApply: Bool {
        !isRunning && proposal != nil && session?.isValid() == true
            && proposalContext == ComposeAssistantContext(compose)
    }
    var canUndo: Bool {
        guard !isRunning, let undoContext else { return false }
        return undoContext.after == ComposeAssistantContext(compose)
    }

    /// Called on live access changes, including while the panel is hidden.
    func refreshAccess() {
        if let session, !session.isValid() || session.scope.accountIDs != Set([compose.draft?.accountID].compactMap { $0 }) {
            clear()
            errorMessage = "Assistant access changed. Start a new request."
        } else if !compose.isEditable { clear() }
    }

    func send() {
        guard !isRunning else { return }
        refreshAccess()
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        do {
            guard request.utf8.count <= 32_768 else { throw AssistantError.historyLimit }
            guard let context = ComposeAssistantContext(compose) else { throw AssistantError.accessChanged }
            let active = try session ?? assistant.makeComposeSession(accountID: context.accountID)
            session = active
            let id = UUID(), messageID = UUID()
            turnID = id; isRunning = true; errorMessage = nil; statusText = "Reading context…"
            proposal = nil; proposalContext = nil
            lastRequest = request; prompt = ""
            messages.append(AssistantMessage(isUser: true, text: request))
            messages.append(AssistantMessage(id: messageID, isUser: false, text: "", state: .streaming))
            task = Task { [weak self] in
                await self?.run(request: request, context: context, session: active, turn: id, messageID: messageID)
            }
        } catch { errorMessage = Self.message(for: error) }
    }

    func retry() {
        guard !isRunning, let lastRequest else { return }
        prompt = lastRequest
        send()
    }

    func stop() {
        task?.cancel(); task = nil; turnID = nil; isRunning = false; statusText = nil
        if let index = messages.lastIndex(where: { $0.state == .streaming }) { messages[index].state = .cancelled }
    }

    func clear() {
        stop(); history = []; messages = []; proposal = nil; proposalContext = nil
        undoContext = nil; previousSuggestion = nil; session = nil; lastRequest = nil; errorMessage = nil; prompt = ""
    }

    func apply() {
        refreshAccess()
        guard canApply, let proposal, let before = proposalContext else {
            errorMessage = "The draft changed. Ask the assistant to update its suggestion before applying it."
            return
        }
        compose.content = before.applying(proposal)
        if let after = ComposeAssistantContext(compose) { undoContext = (before, after) }
        self.proposal = nil; proposalContext = nil; errorMessage = nil
        statusText = "Applied to draft."
    }

    func undo() {
        guard canUndo, let undoContext else {
            errorMessage = "The draft changed after Apply. Undo would overwrite those edits."
            return
        }
        compose.content = undoContext.before.content
        self.undoContext = nil; errorMessage = nil; statusText = "Previous draft restored."
    }

    func waitForCurrentTurn() async { await task?.value }

    private func validate(_ session: ComposeAssistantSession, turn: UUID) throws {
        try Task.checkCancellation()
        guard turnID == turn, session.isValid(), compose.isEditable,
              session.scope.accountIDs == Set([compose.draft?.accountID].compactMap { $0 }) else {
            refreshAccess()
            throw AssistantError.accessChanged
        }
    }

    private func run(request: String, context: ComposeAssistantContext, session: ComposeAssistantSession,
                     turn: UUID, messageID: UUID) async {
        // Publish only a complete, paired transcript. Interrupted read-only work can be retried safely.
        var input = history
        do {
            try validate(session, turn: turn)
            var thread: AIJSON = .null
            if let threadID = context.threadID {
                let args = AIJSON.object(["account_id": .string(context.accountID), "thread_id": .string(threadID)])
                do {
                    let result = try await session.tools.execute(.init(id: UUID().uuidString, namespace: "tern",
                        name: "read_thread", arguments: try args.jsonString()))
                    try validate(session, turn: turn)
                    try accept(result, session: session, messageID: messageID)
                    thread = result.data
                } catch {
                    try validate(session, turn: turn)
                    thread = .object(["unavailable": .bool(true), "reason": .string("The current thread could not be read. Use only supplied draft and quote context and explain the limitation.")])
                }
            }
            input.append(try context.input(request: request, thread: thread, previousSuggestion: previousSuggestion))
            let style = try await session.writingStyle()
            try validate(session, turn: turn)
            let instructions = ComposeAssistantInstructions.text() + "\n" + style
            let readDefinitions = session.tools.definitions.filter { ComposeAssistantSession.readToolNames.contains($0.name) }
            var calls = 0
            for round in 0..<AssistantModel.maximumRounds {
                try validate(session, turn: turn)
                try checkHistory(input)
                let finalRound = round == AssistantModel.maximumRounds - 1
                let canRead = !finalRound && calls < AssistantModel.maximumToolCalls
                let definitions = (canRead ? readDefinitions : []) + [ComposeAssistantProposal.definition]
                let budget = canRead ? "Read only what is relevant. You have \(AssistantModel.maximumRounds - round - 1) reading rounds left."
                    : "No more reads remain. Answer or propose a draft from the evidence already gathered, explaining any unavailable context."
                statusText = "Writing…"
                var completed: AIResponse?
                let prefix = messages.first { $0.id == messageID }?.text ?? ""
                var streamed = ""
                for try await event in session.provider.respond(.init(model: session.model, input: input,
                    instructions: instructions + "\n" + budget, tools: definitions)) {
                    try validate(session, turn: turn)
                    switch event {
                    case .textDelta(let delta):
                        guard completed == nil else { throw AIProviderError.invalidResponse }
                        streamed += delta
                        guard streamed.utf8.count <= AssistantModel.maximumHistoryBytes else { throw AssistantError.historyLimit }
                        update(messageID) { $0.text = Self.join(prefix, streamed) }
                    case .completed(let response):
                        guard completed == nil else { throw AIProviderError.invalidResponse }
                        completed = response
                        update(messageID) { $0.text = Self.join(prefix, response.text) }
                    }
                }
                try validate(session, turn: turn)
                guard let response = completed else { throw AIProviderError.streamInterrupted }
                input += response.output
                guard response.toolCalls.allSatisfy({ call in
                    call.namespace == "tern" && !call.id.isEmpty && definitions.contains(where: { $0.name == call.name })
                }) else {
                    throw AssistantError.invalidTool
                }
                if response.toolCalls.isEmpty {
                    guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || proposal != nil else {
                        throw AIProviderError.incomplete
                    }
                    try checkHistory(input)
                    history = input; finish(turn, messageID: messageID)
                    return
                }
                for call in response.toolCalls {
                    try validate(session, turn: turn)
                    let output: AIJSON
                    if call.name == ComposeAssistantProposal.definition.name {
                        let value = try ComposeAssistantProposal(call: call)
                        proposal = value; proposalContext = context; previousSuggestion = value
                        output = .object(["status": .string("preview_ready"), "applied": .bool(false), "sent": .bool(false)])
                    } else if calls >= AssistantModel.maximumToolCalls {
                        output = .object(["error": .string("Reading limit reached. This operation was not performed.")])
                    } else {
                        // Reject mutations even if a test or future factory advertises them.
                        guard ComposeAssistantSession.readToolNames.contains(call.name) else { throw AssistantError.invalidTool }
                        calls += 1
                        statusText = call.name.contains("calendar") || call.name.contains("availability") ? "Checking calendar…" : "Reading mail…"
                        do {
                            let result = try await session.tools.execute(call)
                            try validate(session, turn: turn)
                            try accept(result, session: session, messageID: messageID)
                            output = result.data
                        } catch {
                            try validate(session, turn: turn)
                            output = .object(["error": .string(Self.message(for: error))])
                        }
                    }
                    input.append(.object(["type": .string("function_call_output"), "call_id": .string(call.id),
                        "output": .string(try output.jsonString())]))
                }
                try checkHistory(input)
                if finalRound, proposal != nil {
                    history = input; finish(turn, messageID: messageID)
                    return
                }
            }
            throw AssistantError.toolLimit
        } catch {
            guard turnID == turn else { return }
            if error is CancellationError { update(messageID) { $0.state = .cancelled } }
            else {
                errorMessage = Self.message(for: error)
                update(messageID) { $0.state = .failed; $0.errorMessage = errorMessage }
            }
            stop()
        }
    }

    private func accept(_ result: AssistantToolResult, session: ComposeAssistantSession, messageID: UUID) throws {
        guard result.createdDraftID == nil, result.calendarProposals.isEmpty,
              result.sources.allSatisfy(session.scope.allows) else { throw AssistantError.invalidSource }
        update(messageID) { message in
            for source in result.sources where !message.sources.contains(source) { message.sources.append(source) }
        }
    }

    private func finish(_ turn: UUID, messageID: UUID) {
        guard turnID == turn else { return }
        update(messageID) {
            $0.state = .completed
            if $0.text.isEmpty { $0.text = "Suggested draft ready to review." }
        }
        task = nil; turnID = nil; isRunning = false; statusText = nil
    }
    private func update(_ id: UUID, _ change: (inout AssistantMessage) -> Void) {
        if let index = messages.firstIndex(where: { $0.id == id }) { change(&messages[index]) }
    }
    private func checkHistory(_ input: [AIJSON]) throws {
        guard input.count <= 160, try AIJSON.array(input).encoded().count <= AssistantModel.maximumHistoryBytes else { throw AssistantError.historyLimit }
    }
    private static func join(_ first: String, _ second: String) -> String {
        first.isEmpty || second.isEmpty ? first + second : first + "\n\n" + second
    }
    private static func message(for error: any Error) -> String {
        if error is AssistantError || error is AIProviderError || error is LocalizedError { return error.localizedDescription }
        return "The assistant could not finish this request. Try again."
    }
}
