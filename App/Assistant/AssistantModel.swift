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
    private(set) var isLoadingModels = false
    private(set) var modelErrorMessage: String?
    var selectedModelID: String {
        didSet {
            defaults?.set(selectedModelID, forKey: Self.modelKey)
            if selectedModelID != oldValue { calendarExtractionRevision += 1 }
        }
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
    private(set) var isCheckingCalendarAvailability = false
    private(set) var calendarChoiceError: String?
    /// Thread readers observe this token to cancel extraction when permission
    /// or model readiness changes; the chat's internal epoch is not observed.
    private(set) var calendarExtractionRevision = 0
    var hasCalendarAccess: Bool { context().calendarScope.hasAccess }
    var hasAssistantDataAccess: Bool { !enabledAccountIDs.isEmpty || hasCalendarAccess }

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
    @ObservationIgnored private var retryContext: RetryContext?
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

    var suggestions: [AssistantSuggestion] {
        context().selectedThreads.isEmpty
            ? [.priorities, .awaitingReplies, .summarizeThread, .draftReply]
            : [.summarizeThread, .draftReply, .priorities, .awaitingReplies]
    }

    func title(for suggestion: AssistantSuggestion) -> String {
        if selectedScope == .selectedThreads {
            if suggestion == .priorities { return "Prioritize these conversations" }
            if suggestion == .awaitingReplies { return "Which of these need a reply?" }
        }
        if suggestion == .summarizeThread, context().selectedThreads.count > 1 {
            return "Summarize these conversations"
        }
        return suggestion.title
    }

    func requirement(for suggestion: AssistantSuggestion) -> String? {
        if isRunning { return "Wait for this reply or stop it first." }
        let current = context()
        let selection = suggestionScope(suggestion)
        let snapshot = scope(in: current, selection: selection)
        do {
            try validateStart(snapshot, selection: selection)
            guard snapshot.accountIDs.isSubset(of: scope(in: current).accountIDs) else {
                return "Select a conversation within the current mail scope."
            }
            if suggestion == .draftReply, snapshot.threadIDs?.count != 1 {
                return "Select one conversation to draft a reply."
            }
            return nil
        } catch { return Self.message(for: error) }
    }

    func canRun(_ suggestion: AssistantSuggestion) -> Bool { requirement(for: suggestion) == nil }

    func run(_ suggestion: AssistantSuggestion) {
        refreshAccess()
        if let requirement = requirement(for: suggestion) { errorMessage = requirement; return }
        selectedScope = suggestionScope(suggestion)
        let prompt: String
        if selectedScope == .selectedThreads, suggestion == .priorities {
            prompt = "What needs my attention in the selected conversations? Identify open requests and upcoming deadlines, check for later replies that resolve them, and show the conversations in priority order."
        } else if selectedScope == .selectedThreads, suggestion == .awaitingReplies {
            prompt = "Which of the selected conversations need my reply? Read the latest messages, exclude anything already answered, and show the conversations with a short reason."
        } else { prompt = suggestion.prompt }
        send(prompt)
    }

    private func suggestionScope(_ suggestion: AssistantSuggestion) -> AssistantScope {
        if suggestion.requiresSelection { return .selectedThreads }
        return selectedScope
    }

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
        if observedScope?.connectionRevision != current.connectionRevision { modelErrorMessage = nil }
        if let previous = observedScope {
            if previous != snapshot { clearConversation() }
        } else { calendarExtractionRevision += 1 }
        observedScope = snapshot
        if catalogueRevision != current.connectionRevision {
            models = []
            catalogueRevision = nil
        }
        if let revision = catalogueTaskRevision, revision != current.connectionRevision {
            catalogueTask?.cancel(); catalogueTask = nil; catalogueTaskRevision = nil; catalogueTaskID = nil
            isLoadingModels = false
        }
    }

    func refreshConnection() async {
        await connection.recoverPendingConnection()
        refreshAccess()
        let current = context()
        guard current.canUsePlan else { models = []; modelErrorMessage = nil; isLoadingModels = false; return }
        isLoadingModels = true
        modelErrorMessage = nil
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
            if catalogueTaskID == requestID {
                catalogueTask = nil; catalogueTaskRevision = nil; catalogueTaskID = nil
                isLoadingModels = false
            }
        }
        do {
            let choices = try await request.value
            guard context().connectionRevision == revision, context().canUsePlan else {
                refreshAccess(); return
            }
            models = choices
            catalogueRevision = revision
            if !choices.contains(where: { $0.id == selectedModelID }) { selectedModelID = choices.first?.id ?? "" }
            calendarExtractionRevision += 1
            modelErrorMessage = choices.isEmpty ? "No models are available for this ChatGPT connection." : nil
        } catch {
            guard context().connectionRevision == revision else { refreshAccess(); return }
            models = []
            modelErrorMessage = Self.message(for: error)
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
            let input = history + [Self.userInput(prompt)]
            try checkHistory(input)
            let tools = try tools(for: snapshot)
            let messageID = UUID()
            messages.append(AssistantMessage(isUser: true, text: prompt))
            messages.append(AssistantMessage(id: messageID, isUser: false, text: "", state: .streaming))
            retryContext = RetryContext(messageID: messageID, scope: snapshot, epoch: conversationEpoch)
            history = input
            start(input: input, snapshot: snapshot, tools: tools, messageID: messageID, isRetry: false)
        } catch { errorMessage = Self.message(for: error) }
    }

    func canRetry(_ messageID: UUID) -> Bool {
        guard !isRunning, let retryContext, retryContext.messageID == messageID,
              retryContext.epoch == conversationEpoch, retryContext.scope == scope(in: context()),
              messages.last?.id == messageID, messages.last?.state == .failed else { return false }
        do { try validateStart(retryContext.scope); try checkHistory(history); return true }
        catch { return false }
    }

    func retry(_ messageID: UUID) {
        refreshAccess()
        guard canRetry(messageID), let retryContext else { return }
        do {
            let tools = try tools(for: retryContext.scope)
            update(messageID) {
                $0.text = ""; $0.state = .streaming; $0.errorMessage = nil
            }
            start(input: history, snapshot: retryContext.scope, tools: tools, messageID: messageID, isRetry: true)
        } catch { errorMessage = Self.message(for: error) }
    }

    private func start(input: [AIJSON], snapshot: AssistantScopeSnapshot, tools: AssistantToolSession,
                       messageID: UUID, isRetry: Bool) {
        let id = UUID()
        turnID = id; isRunning = true; errorMessage = nil; usage = nil; statusText = "Thinking…"
        let model = selectedModelID
        task = Task { [weak self] in
            await self?.run(input: input, model: model, snapshot: snapshot, tools: tools,
                            turn: id, messageID: messageID, isRetry: isRetry)
        }
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

    func reviewCalendarProposal(_ proposal: AssistantCalendarProposal) {
        refreshAccess()
        let scope = context().calendarScope
        guard scope.revision == proposal.accessRevision, scope.allows(proposal.calendar),
              messages.contains(where: { $0.calendarProposals.contains(proposal) }) else { return }
        app?.calendar.openProposal(proposal.id)
    }

    func useAvailabilityChoices(_ choices: [AssistantAvailabilityChoice]) async {
        guard !isRunning, !isCheckingCalendarAvailability, !choices.isEmpty, choices.count <= 6,
              let app else { return }
        refreshAccess()
        let snapshot = scope(in: context())
        let epoch = conversationEpoch
        let known = Set(messages.flatMap(\.availabilityChoices).map(\.id))
        guard choices.allSatisfy({ known.contains($0.id) && $0.accessRevision == snapshot.calendarScope.revision
            && $0.calendarKeys.allSatisfy { snapshot.calendarScope.allows($0) } }) else { return }
        isCheckingCalendarAvailability = true
        calendarChoiceError = nil
        defer { isCheckingCalendarAvailability = false }
        let bindings = app.calendar.assistantBindings
        do {
            for choice in choices {
                var hours = bindings.workingHours()
                hours.timeZoneIdentifier = choice.timeZoneIdentifier
                hours.durationMinutes = Int(choice.end.timeIntervalSince(choice.start) / 60)
                guard choice.start > .now else { throw CalendarAssistantTools.ToolError.changedSlot }
                let result = try await CalendarAssistantTools.check(keys: choice.calendarKeys, start: choice.start,
                    end: choice.end, hours: hours, bindings: bindings) { [weak self] in
                        guard let self, self.conversationEpoch == epoch,
                              self.scope(in: self.context()) == snapshot else { throw AssistantError.accessChanged }
                    }
                guard result.isComplete else { throw CalendarAssistantTools.ToolError.incompleteAvailability }
                guard result.slots.contains(where: { $0.start == choice.start && $0.end == choice.end }) else {
                    throw CalendarAssistantTools.ToolError.changedSlot
                }
            }
            guard conversationEpoch == epoch, scope(in: context()) == snapshot else { throw AssistantError.accessChanged }
            guard !isRunning else {
                calendarChoiceError = "Wait for the current assistant reply, then choose these times again."
                return
            }
            let times = choices.map { "\($0.displayTitle) (\($0.timeZoneIdentifier))" }.joined(separator: "\n")
            send("Prepare an editable reply proposing only these times I selected, which Tern just checked again:\n\(times)\nDo not reserve an event or send the reply. Do not include details about my other appointments. If the reply target is unclear, ask me which conversation to reply to.")
        } catch {
            guard conversationEpoch == epoch else { return }
            calendarChoiceError = error.localizedDescription
        }
    }

    func calendarExtractionService(for thread: ThreadKey) throws -> EmailCalendarExtractionService {
        refreshAccess()
        let snapshot = scope(in: context())
        try validateStart(snapshot)
        guard snapshot.accountIDs.contains(thread.accountID),
              snapshot.threadIDs?.contains(thread) ?? true else { throw AssistantError.accessChanged }
        let epoch = conversationEpoch
        let model = selectedModelID
        return EmailCalendarExtractionService(provider: provider, model: model) { [weak self] in
            guard let self else { return false }
            return conversationEpoch == epoch && scope(in: context()) == snapshot
                && selectedModelID == model && catalogueRevision == snapshot.connectionRevision
                && models.contains(where: { $0.id == model })
        }
    }

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
            connectionRevision: connection.connectionRevision, canUsePlan: connection.canUsePlan,
            calendarScope: app?.calendar.assistantScope ?? AssistantCalendarScope())
    }

    private func scope(in current: AssistantContext, selection: AssistantScope? = nil) -> AssistantScopeSnapshot {
        let enabled = enabledAccountIDs.intersection(current.accountInstances.keys)
        let accounts: Set<String>
        let threads: Set<ThreadKey>?
        switch selection ?? selectedScope {
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
            connectionRevision: current.connectionRevision, canUsePlan: current.canUsePlan,
            calendarScope: current.calendarScope)
    }

    private func validateStart(_ snapshot: AssistantScopeSnapshot, selection: AssistantScope? = nil) throws {
        guard snapshot.canUsePlan else { throw AIProviderError.signInRequired }
        if !snapshot.calendarScope.hasAccess, (selection ?? selectedScope) == .selectedThreads,
           snapshot.threadIDs?.isEmpty != false { throw AssistantError.noSelection }
        guard !snapshot.accountIDs.isEmpty || snapshot.calendarScope.hasAccess else { throw AssistantError.noAccounts }
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
            let isValid: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                return conversationEpoch == epoch && scope(in: context()) == snapshot
            }
            let tools = MailAssistantTools(app: app, allowedAccountIDs: snapshot.accountIDs,
                allowedThreadIDs: snapshot.threadIDs, isScopeValid: isValid)
            let calendarTools = CalendarAssistantTools(scope: snapshot.calendarScope,
                bindings: app.calendar.assistantBindings, isScopeValid: isValid)
            let mailDefinitions = snapshot.accountIDs.isEmpty ? [] : MailAssistantTools.definitions
            let calendarDefinitions = snapshot.calendarScope.hasAccess ? CalendarAssistantTools.definitions : []
            session = AssistantToolSession(definitions: mailDefinitions + calendarDefinitions,
                acknowledge: { tools.acknowledge(callID: $0) },
                execute: { call in
                    if calendarDefinitions.contains(where: { $0.name == call.name }) {
                        return try await calendarTools.execute(call)
                    }
                    return try await tools.execute(call)
                })
        }
        toolSession = session
        return session
    }

    private func clearConversation() {
        stop(); conversationEpoch += 1
        calendarExtractionRevision += 1
        history = []; messages = []; toolSession = nil; composerText = ""
        retryContext = nil
        errorMessage = nil; usage = nil
        calendarChoiceError = nil
        app?.calendar.clearAssistantProposals()
    }

    private func ensureCurrent(_ snapshot: AssistantScopeSnapshot, turn: UUID) throws {
        try Task.checkCancellation()
        guard turnID == turn, scope(in: context()) == snapshot else {
            refreshAccess()
            throw AssistantError.accessChanged
        }
    }

    private func run(input initialInput: [AIJSON], model: String, snapshot: AssistantScopeSnapshot,
                     tools: AssistantToolSession, turn: UUID, messageID: UUID, isRetry: Bool) async {
        var input = initialInput
        var callCount = 0
        var answerNext = false
        var finalizeNext = false
        let hasPreparedDraft = messages.first(where: { $0.id == messageID })?.draftIDs.isEmpty == false
        let definitions = isRetry && hasPreparedDraft ? tools.definitions.filter { $0.name != "prepare_draft" } : tools.definitions
        do {
            var instructions = try AssistantInstructions.chat(scope: snapshot, accounts: context().accounts)
            if isRetry {
                instructions += "\nContinue the existing user request from the completed tool results in this history. Do not repeat completed actions. If a draft was already prepared, describe it so the user can open it; preparing another draft requires a new user request."
            }
            for round in 0..<Self.maximumRounds {
                try ensureCurrent(snapshot, turn: turn)
                try checkHistory(input)
                let answerOnly = answerNext || round == Self.maximumRounds - 1
                let presentationOnly = !answerOnly && (finalizeNext || round >= Self.maximumRounds - 2 || callCount >= Self.maximumToolCalls - 1)
                let roundDefinitions = answerOnly ? [] : (presentationOnly ? definitions.filter { $0.name == "present_emails" } : definitions)
                let allowance = answerOnly ? 0 : (presentationOnly ? min(1, Self.maximumToolCalls - callCount) : Self.maximumToolCalls - 1 - callCount)
                let budgetInstructions: String
                if answerOnly {
                    budgetInstructions = "This is the final response. No tools remain. Answer from completed results and displayed conversations. State any incomplete coverage or skipped operations; never claim a skipped action succeeded."
                } else if presentationOnly {
                    budgetInstructions = "Reading and action time is over. Use one present_emails call to select up to five relevant retrieved conversations, then answer from completed results. If no emails are relevant, answer directly. Do not request more reads or actions."
                } else {
                    budgetInstructions = "You have \(Self.maximumRounds - 2 - round) reading rounds and \(allowance) tool calls left before presentation and the final answer. Read at most five promising conversations; use search metadata to choose them. Finish early when you have enough evidence, and mention any incomplete coverage."
                }
                var completed: AIResponse?
                let prefix = messages.first(where: { $0.id == messageID })?.text ?? ""
                var streamedText = ""
                for try await event in provider.respond(AIRequest(model: model, input: input,
                    instructions: instructions + "\n" + budgetInstructions, tools: roundDefinitions)) {
                    try ensureCurrent(snapshot, turn: turn)
                    switch event {
                    case .textDelta(let delta):
                        guard completed == nil else { throw AIProviderError.malformedResponse(.terminalEnvelope) }
                        streamedText += delta
                        update(messageID) { $0.text = Self.joinReply(prefix, streamedText) }
                    case .completed(let response):
                        guard completed == nil else { throw AIProviderError.malformedResponse(.terminalEnvelope) }
                        completed = response
                        update(messageID) { $0.text = Self.joinReply(prefix, response.text) }
                    }
                }
                try ensureCurrent(snapshot, turn: turn)
                guard let response = completed else { throw AIProviderError.streamInterrupted }
                input += response.output
                usage = response.usage
                if response.toolCalls.isEmpty {
                    let visible = messages.first(where: { $0.id == messageID })
                    let hasOutcome = !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (visible.map {
                        !$0.emailResults.isEmpty || !$0.draftIDs.isEmpty
                            || !$0.calendarProposals.isEmpty || !$0.availabilityChoices.isEmpty
                    } ?? false)
                    if !hasOutcome {
                        if !answerOnly, round < Self.maximumRounds - 1 {
                            try checkHistory(input)
                            history = input
                            if presentationOnly { answerNext = true } else { finalizeNext = true }
                            statusText = "Finishing answer…"
                            continue
                        }
                        throw AssistantError.emptyReply(outputItems: response.output.count,
                            reasoningItems: response.output.filter { $0["type"]?.stringValue == "reasoning" }.count)
                    }
                    try checkHistory(input)
                    history = input
                    update(messageID) { $0.state = .completed }
                    retryContext = nil
                    finish(turn)
                    return
                }
                guard response.toolCalls.allSatisfy({ call in
                    call.namespace == "tern" && roundDefinitions.contains(where: { $0.name == call.name })
                }) else { throw AssistantError.invalidTool }
                var attemptedThisRound = 0
                for (index, call) in response.toolCalls.enumerated() {
                    try ensureCurrent(snapshot, turn: turn)
                    guard attemptedThisRound < allowance else {
                        let skipped = AIJSON.object([
                            "status": .string("not_run"),
                            "error": .string("This operation was not run because the request's tool budget is spent. No action was performed. Finish using the completed results and explain any remaining work."),
                        ])
                        input.append(try Self.toolOutput(call.id, data: skipped))
                        try checkpoint(input, pending: Array(response.toolCalls.dropFirst(index + 1)))
                        continue
                    }
                    try checkpoint(input, pending: Array(response.toolCalls.dropFirst(index)), uncertainDraft: call.name == "prepare_draft" ? call.id : nil)
                    statusText = call.name == "prepare_draft" ? "Preparing draft…"
                        : (CalendarAssistantTools.definitions.contains(where: { $0.name == call.name }) ? "Checking calendar…" : "Reading mail…")
                    let output: AIJSON
                    var acceptedResult: MailAssistantToolResult?
                    do {
                        attemptedThisRound += 1
                        callCount += 1
                        let result = try await tools.execute(call)
                        try ensureCurrent(snapshot, turn: turn)
                        guard result.sources.allSatisfy(snapshot.allows),
                              result.emailResults.allSatisfy({ !$0.source.isCalendar && snapshot.allows($0.source) }),
                              result.emailResults.isEmpty || call.name == "present_emails",
                              result.calendarProposals.allSatisfy({ $0.accessRevision == snapshot.calendarScope.revision && snapshot.calendarScope.allows($0.calendar) }),
                              result.availabilityChoices.allSatisfy({ $0.accessRevision == snapshot.calendarScope.revision && $0.calendarKeys.allSatisfy { snapshot.calendarScope.allows($0) } })
                        else { throw AssistantError.invalidSource }
                        output = result.data
                        update(messageID) { message in
                            for source in result.sources where !message.sources.contains(where: { $0.id == source.id }) { message.sources.append(source) }
                            if let id = result.createdDraftID, !message.draftIDs.contains(id) { message.draftIDs.append(id) }
                            if call.name == "present_emails" { message.emailResults = result.emailResults }
                            for proposal in result.calendarProposals where !message.calendarProposals.contains(where: { $0.id == proposal.id }) {
                                message.calendarProposals.append(proposal)
                            }
                            for choice in result.availabilityChoices where !message.availabilityChoices.contains(where: { $0.id == choice.id }) {
                                message.availabilityChoices.append(choice)
                            }
                        }
                        acceptedResult = result
                    } catch {
                        try ensureCurrent(snapshot, turn: turn)
                        output = .object(["error": .string(Self.toolMessage(for: error))])
                    }
                    input.append(try Self.toolOutput(call.id, data: output))
                    try checkpoint(input, pending: Array(response.toolCalls.dropFirst(index + 1)))
                    // Delivery is accepted only once its outcome is retained.
                    // A cancelled caller leaves its reservation available for retry.
                    if acceptedResult != nil { tools.acknowledge(call.id) }
                }
                if presentationOnly { answerNext = true }
                statusText = "Thinking…"
            }
            throw AssistantError.toolLimit
        } catch {
            guard turnID == turn else { return }
            if error is CancellationError { update(messageID) { $0.state = .cancelled } }
            else {
                let description = Self.message(for: error)
                errorMessage = description
                update(messageID) { $0.state = .failed; $0.errorMessage = description }
            }
            finish(turn)
        }
    }

    private func update(_ id: UUID, _ change: (inout AssistantMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private static func joinReply(_ earlier: String, _ later: String) -> String {
        guard !earlier.isEmpty, !later.isEmpty else { return earlier + later }
        return earlier + "\n\n" + later
    }

    private struct RetryContext {
        let messageID: UUID
        let scope: AssistantScopeSnapshot
        let epoch: Int
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
        if error is AttachmentTextReader.ReadError || error is AssistantMailError || error is MailAssistantTools.ToolError || error is CalendarAssistantTools.ToolError {
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
