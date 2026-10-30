import Foundation
import MailStore
import Observation
import SyncEngine
import TernAI

@MainActor
@Observable
final class AssistantModel {
    let connection: ChatGPTConnection
    private(set) var models: [AIModel] = []
    var selectedModelID: String {
        didSet { defaults?.set(selectedModelID, forKey: Self.modelKey) }
    }
    private(set) var messages: [AssistantMessage] = []
    var composerText = ""
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private(set) var statusText: String?
    private(set) var usage: AIUsage?
    var selectedScope: AssistantScope = .selectedThreads {
        didSet { if selectedScope != oldValue { refreshAccess() } }
    }
    private(set) var enabledAccountIDs: Set<String>

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let provider: any AIProvider
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let contextOverride: (@MainActor () -> AssistantContext)?
    @ObservationIgnored private let toolFactory: (@MainActor (AssistantScopeSnapshot) -> AssistantToolSession)?
    @ObservationIgnored private var history: [AIJSON] = []
    @ObservationIgnored private var observedScope: AssistantScopeSnapshot?
    @ObservationIgnored private var toolSession: AssistantToolSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var turnID: UUID?
    @ObservationIgnored private var conversationEpoch = 0
    @ObservationIgnored private var catalogueRevision: Int?
    @ObservationIgnored private var catalogueTask: Task<[AIModel], any Error>?
    @ObservationIgnored private var catalogueTaskRevision: Int?
    @ObservationIgnored private var catalogueTaskID: UUID?

    private static let modelKey = "assistant.selectedModel"
    private static let accountsKey = "assistant.enabledAccounts"
    static let maximumHistoryBytes = 180_000
    static let maximumToolCalls = 24
    static let maximumRounds = 8

    init(app: AppModel, connection: ChatGPTConnection = ChatGPTConnection(),
         provider: (any AIProvider)? = nil, defaults: UserDefaults? = nil,
         context: (@MainActor () -> AssistantContext)? = nil,
         makeTools: (@MainActor (AssistantScopeSnapshot) -> AssistantToolSession)? = nil) {
        let persistence: UserDefaults?
        if let defaults { persistence = defaults }
        else if AssistantRuntimeEnvironment.isTestHost { persistence = nil }
        else { persistence = .standard }
        // A hosted view with synthetic accounts must never read or prune the
        // user's preferences. Without persistence, these values stay in memory.
        self.app = app; self.connection = connection; self.defaults = persistence
        self.contextOverride = context; self.toolFactory = makeTools
        self.provider = provider ?? ChatGPTProvider(accessToken: { [weak connection] in
            guard let connection else { throw AIProviderError.signInRequired }
            return try await connection.accessToken()
        })
        selectedModelID = persistence?.string(forKey: Self.modelKey) ?? ""
        enabledAccountIDs = Set(persistence?.stringArray(forKey: Self.accountsKey) ?? [])
    }

    var availableAccounts: [AccountRecord] { context().accounts }

    func setAccountEnabled(_ id: String, enabled: Bool) {
        guard availableAccounts.contains(where: { $0.id == id }) else { return }
        if enabled { enabledAccountIDs.insert(id) } else { enabledAccountIDs.remove(id) }
        defaults?.set(enabledAccountIDs.sorted(), forKey: Self.accountsKey)
        refreshAccess()
    }

    /// Also called by mailbox lifecycle observers while no request is active.
    func refreshAccess() {
        let current = context()
        // Restored windows can ask for access before the mailbox has loaded.
        // An unavailable account list must not erase persisted opt-ins.
        if current.isAccountListReady {
            let retained = enabledAccountIDs.intersection(current.accounts.map(\.id))
            if retained != enabledAccountIDs {
                enabledAccountIDs = retained
                defaults?.set(retained.sorted(), forKey: Self.accountsKey)
            }
        }
        let snapshot = scope(in: current)
        if let previous = observedScope, previous != snapshot { clearConversation() }
        observedScope = snapshot
        if catalogueRevision != current.connectionRevision {
            models = []
            catalogueRevision = nil
        }
        if let revision = catalogueTaskRevision, revision != current.connectionRevision {
            catalogueTask?.cancel(); catalogueTask = nil; catalogueTaskRevision = nil; catalogueTaskID = nil
        }
    }

    func refreshConnection() async {
        await connection.recoverPendingConnection()
        refreshAccess()
        let current = context()
        guard current.canUsePlan else { models = []; return }
        let revision = current.connectionRevision
        let request: Task<[AIModel], any Error>
        let requestID: UUID
        if let catalogueTask, let catalogueTaskID, catalogueTaskRevision == revision {
            request = catalogueTask; requestID = catalogueTaskID
        }
        else {
            request = Task { [provider] in try await provider.models() }
            requestID = UUID()
            catalogueTask = request; catalogueTaskRevision = revision; catalogueTaskID = requestID
        }
        defer {
            if catalogueTaskID == requestID { catalogueTask = nil; catalogueTaskRevision = nil; catalogueTaskID = nil }
        }
        do {
            let choices = try await request.value
            guard context().connectionRevision == revision, context().canUsePlan else {
                refreshAccess(); return
            }
            models = choices
            catalogueRevision = revision
            if !choices.contains(where: { $0.id == selectedModelID }) { selectedModelID = choices.first?.id ?? "" }
            if choices.isEmpty { errorMessage = "No models are available for this ChatGPT connection." }
            else { errorMessage = nil }
        } catch {
            guard context().connectionRevision == revision else { refreshAccess(); return }
            models = []
            errorMessage = Self.message(for: error)
        }
    }

    func send(_ text: String) {
        guard !isRunning else { return }
        refreshAccess()
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let snapshot = scope(in: context())
        do {
            try validateStart(snapshot)
            guard prompt.utf8.count <= 32_768 else { throw AssistantError.historyLimit }
            try checkHistory(history + [Self.userInput(prompt)])
            let tools = try tools(for: snapshot)
            let id = UUID()
            let messageID = UUID()
            turnID = id; isRunning = true; errorMessage = nil; usage = nil
            statusText = "Thinking…"
            messages.append(AssistantMessage(isUser: true, text: prompt))
            messages.append(AssistantMessage(id: messageID, isUser: false, text: "", state: .streaming))
            let model = selectedModelID
            task = Task { [weak self] in
                await self?.run(prompt, model: model, snapshot: snapshot, tools: tools, turn: id, messageID: messageID)
            }
        } catch { errorMessage = Self.message(for: error) }
    }

    func stop() {
        task?.cancel(); task = nil; turnID = nil
        if let index = messages.lastIndex(where: { $0.state == .streaming }) {
            messages[index].state = .cancelled
        }
        isRunning = false; statusText = nil
    }

    func newChat() { clearConversation(); observedScope = scope(in: context()) }

    /// Allows callers to await a submitted turn without polling its UI state.
    func waitForCurrentTurn() async { await task?.value }

    func summarize(thread: ThreadKey) async throws -> AssistantSummary {
        refreshAccess()
        let snapshot = scope(in: context())
        try validateStart(snapshot)
        guard snapshot.accountIDs.contains(thread.accountID),
              snapshot.threadIDs?.contains(thread) ?? true else { throw AssistantError.accessChanged }
        let epoch = conversationEpoch
        let service = AssistantSummaryService(provider: provider, model: selectedModelID, tools: try tools(for: snapshot)) { [weak self] in
            guard let self else { return false }
            return conversationEpoch == epoch && scope(in: context()) == snapshot
        }
        return try await service.summarize(thread: thread)
    }

    private func context() -> AssistantContext {
        if let contextOverride { return contextOverride() }
        let mailbox = app?.mailbox
        let accounts = mailbox?.accounts ?? []
        let hasMailboxAccess: Bool
        if let app, case .signedIn = app.phase { hasMailboxAccess = true } else { hasMailboxAccess = false }
        let eligible = accounts.filter { hasMailboxAccess && app?.accountsNeedingSignIn.contains($0.account.id) != true }
        return AssistantContext(
            accounts: accounts.map(\.account), isAccountListReady: hasMailboxAccess && mailbox != nil,
            currentAccountIDs: Set(mailbox?.selectedAccounts.map(\.account.id) ?? []),
            selectedThreads: mailbox?.selectedThreadIDs ?? [],
            accountInstances: Dictionary(uniqueKeysWithValues: eligible.map { ($0.account.id, String(describing: ObjectIdentifier($0))) }),
            connectionRevision: connection.connectionRevision, canUsePlan: connection.canUsePlan)
    }

    private func scope(in current: AssistantContext) -> AssistantScopeSnapshot {
        let enabled = enabledAccountIDs.intersection(current.accountInstances.keys)
        let accounts: Set<String>
        let threads: Set<ThreadKey>?
        switch selectedScope {
        case .selectedThreads:
            let selected = current.selectedThreads.filter { enabled.contains($0.accountID) }
            threads = Set(selected); accounts = Set(selected.map(\.accountID))
        case .currentAccount:
            accounts = enabled.intersection(current.currentAccountIDs); threads = nil
        case .allEnabledAccounts:
            accounts = enabled; threads = nil
        }
        return AssistantScopeSnapshot(accountIDs: accounts, threadIDs: threads,
            accountInstances: current.accountInstances.filter { accounts.contains($0.key) },
            connectionRevision: current.connectionRevision, canUsePlan: current.canUsePlan)
    }

    private func validateStart(_ snapshot: AssistantScopeSnapshot) throws {
        guard snapshot.canUsePlan else { throw AIProviderError.signInRequired }
        if selectedScope == .selectedThreads, snapshot.threadIDs?.isEmpty != false { throw AssistantError.noSelection }
        guard !snapshot.accountIDs.isEmpty else { throw AssistantError.noAccounts }
        guard !selectedModelID.isEmpty, models.contains(where: { $0.id == selectedModelID }),
              catalogueRevision == snapshot.connectionRevision else { throw AssistantError.noModel }
    }

    private func tools(for snapshot: AssistantScopeSnapshot) throws -> AssistantToolSession {
        if let toolSession { return toolSession }
        let session: AssistantToolSession
        if let toolFactory { session = toolFactory(snapshot) }
        else {
            guard let app else { throw AssistantError.accessChanged }
            let epoch = conversationEpoch
            let tools = MailAssistantTools(app: app, allowedAccountIDs: snapshot.accountIDs, allowedThreadIDs: snapshot.threadIDs) { [weak self] in
                guard let self else { return false }
                return conversationEpoch == epoch && scope(in: context()) == snapshot
            }
            session = AssistantToolSession(definitions: MailAssistantTools.definitions,
                acknowledge: { tools.acknowledge(callID: $0) },
                execute: { try await tools.execute($0) })
        }
        toolSession = session
        return session
    }

    private func clearConversation() {
        stop(); conversationEpoch += 1
        history = []; messages = []; toolSession = nil; composerText = ""
        errorMessage = nil; usage = nil
    }

    private func ensureCurrent(_ snapshot: AssistantScopeSnapshot, turn: UUID) throws {
        try Task.checkCancellation()
        guard turnID == turn, scope(in: context()) == snapshot else {
            refreshAccess()
            throw AssistantError.accessChanged
        }
    }

    private func run(_ prompt: String, model: String, snapshot: AssistantScopeSnapshot,
                     tools: AssistantToolSession, turn: UUID, messageID: UUID) async {
        var input = history + [Self.userInput(prompt)]
        var callCount = 0
        do {
            let instructions = try AssistantInstructions.chat(scope: snapshot, accounts: context().accounts)
            for _ in 0..<Self.maximumRounds {
                try ensureCurrent(snapshot, turn: turn)
                try checkHistory(input)
                var completed: AIResponse?
                let prefix = messages.first(where: { $0.id == messageID })?.text ?? ""
                for try await event in provider.respond(AIRequest(model: model, input: input, instructions: instructions, tools: tools.definitions)) {
                    try ensureCurrent(snapshot, turn: turn)
                    switch event {
                    case .textDelta(let delta):
                        guard completed == nil else { throw AIProviderError.malformedResponse(.terminalEnvelope) }
                        update(messageID) { $0.text += delta }
                    case .completed(let response):
                        guard completed == nil else { throw AIProviderError.malformedResponse(.terminalEnvelope) }
                        completed = response
                        update(messageID) { $0.text = prefix + response.text }
                    }
                }
                try ensureCurrent(snapshot, turn: turn)
                guard let response = completed else { throw AIProviderError.streamInterrupted }
                input += response.output
                usage = response.usage
                if response.toolCalls.isEmpty {
                    guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AssistantError.emptyReply(outputItems: response.output.count,
                            reasoningItems: response.output.filter { $0["type"]?.stringValue == "reasoning" }.count)
                    }
                    try checkHistory(input)
                    history = input
                    update(messageID) { $0.state = .completed }
                    finish(turn)
                    return
                }
                callCount += response.toolCalls.count
                guard callCount <= Self.maximumToolCalls else { throw AssistantError.toolLimit }
                guard response.toolCalls.allSatisfy({ call in
                    call.namespace == "tern" && tools.definitions.contains(where: { $0.name == call.name })
                }) else { throw AssistantError.invalidTool }
                for (index, call) in response.toolCalls.enumerated() {
                    try ensureCurrent(snapshot, turn: turn)
                    try checkpoint(input, pending: Array(response.toolCalls.dropFirst(index)), uncertainDraft: call.name == "prepare_draft" ? call.id : nil)
                    statusText = call.name == "prepare_draft" ? "Preparing draft…" : "Reading mail…"
                    let output: AIJSON
                    var acceptedResult = false
                    do {
                        let result = try await tools.execute(call)
                        try ensureCurrent(snapshot, turn: turn)
                        guard result.sources.allSatisfy(snapshot.allows) else { throw AssistantError.invalidSource }
                        output = result.data
                        update(messageID) { message in
                            for source in result.sources where !message.sources.contains(where: { $0.id == source.id }) { message.sources.append(source) }
                            if let id = result.createdDraftID, !message.draftIDs.contains(id) { message.draftIDs.append(id) }
                        }
                        acceptedResult = true
                    } catch {
                        try ensureCurrent(snapshot, turn: turn)
                        output = .object(["error": .string(Self.toolMessage(for: error))])
                    }
                    input.append(try Self.toolOutput(call.id, data: output))
                    try checkpoint(input, pending: Array(response.toolCalls.dropFirst(index + 1)))
                    // Delivery is accepted only once its outcome is retained.
                    // A cancelled caller leaves its reservation available for retry.
                    if acceptedResult { tools.acknowledge(call.id) }
                }
                statusText = "Thinking…"
            }
            throw AssistantError.toolLimit
        } catch {
            guard turnID == turn else { return }
            if error is CancellationError { update(messageID) { $0.state = .cancelled } }
            else { errorMessage = Self.message(for: error); update(messageID) { $0.state = .failed } }
            finish(turn)
        }
    }

    private func update(_ id: UUID, _ change: (inout AssistantMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }
    /// Every checkpoint has an output for each call, including work not reached
    /// before cancellation. Completed drafts must survive a later read failure.
    private func checkpoint(_ input: [AIJSON], pending: [AIToolCall], uncertainDraft: String? = nil) throws {
        var complete = input
        for call in pending {
            let explanation = call.id == uncertainDraft
                ? "This draft request was interrupted and may have created an unsent draft. Check Drafts before preparing a replacement."
                : "This operation was not completed before the request stopped."
            complete.append(try Self.toolOutput(call.id, data: .object(["error": .string(explanation)])))
        }
        // Preserve action outcomes even if this round fills the context budget;
        // the budget check prevents another request until the user starts anew.
        history = complete
        try checkHistory(complete)
    }
    private static func toolOutput(_ callID: String, data: AIJSON) throws -> AIJSON {
        .object(["type": .string("function_call_output"), "call_id": .string(callID), "output": .string(try data.jsonString())])
    }
    private static func toolMessage(for error: any Error) -> String {
        if error is AttachmentTextReader.ReadError || error is AssistantMailError || error is MailAssistantTools.ToolError {
            return error.localizedDescription
        }
        return "This operation did not complete. Narrow the request or explain the limitation to the user."
    }
    private func finish(_ turn: UUID) {
        guard turnID == turn else { return }
        isRunning = false; statusText = nil; task = nil; turnID = nil
    }
    private func checkHistory(_ input: [AIJSON]) throws {
        guard input.count <= 160, try AIJSON.array(input).encoded().count <= Self.maximumHistoryBytes else { throw AssistantError.historyLimit }
    }
    private static func userInput(_ text: String) -> AIJSON { .object(["role": .string("user"), "content": .string(text)]) }
    private static func message(for error: any Error) -> String {
        if error is AssistantError || error is AIProviderError || error is ChatGPTAuthError || error is ChatGPTConnectionError {
            return error.localizedDescription
        }
        return "Tern couldn't complete this request. Please try again."
    }
}
