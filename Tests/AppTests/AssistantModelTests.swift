import Foundation
import MailStore
import SyncEngine
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct AssistantModelTests {
    @Test(arguments: [false, true])
    func streamedBurstsKeepAllPartialTextAndUseTheAuthoritativeCompletion(completes: Bool) async throws {
        let fragments = ["First"] + Array(repeating: " fragment", count: 200)
        let provider = AssistantProviderFixture(replies: [.streamed(fragments, completes ? Self.answer("Final answer") : nil)])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Answer briefly")
        await fixture.model.waitForCurrentTurn()

        #expect(fixture.model.messages.last?.text == (completes ? "Final answer" : fragments.joined()))
        #expect(fixture.model.messages.last?.state == (completes ? .completed : .failed))
    }

    @Test(arguments: [false, true])
    func stoppingStreamKeepsItsPendingTailUnlessAccessWasRevoked(revokeAccess: Bool) async throws {
        let provider = AssistantProviderFixture(replies: [.streamedSuspended(["First", " tail"])])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Answer briefly")
        await provider.waitForRequests(1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while fixture.model.messages.last?.text.isEmpty != false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(fixture.model.messages.last?.text.isEmpty == false)
        await Task.yield()

        if revokeAccess { fixture.model.setAccountEnabled("a", enabled: false) }
        else { fixture.model.stop() }
        if revokeAccess { #expect(fixture.model.messages.isEmpty) }
        else {
            #expect(fixture.model.messages.last?.text == "First tail")
            #expect(fixture.model.messages.last?.state == .cancelled)
        }
        await provider.release(Self.answer("Late private answer"))
        try await Task.sleep(for: .milliseconds(80))
        if revokeAccess { #expect(fixture.model.messages.isEmpty) }
        else { #expect(fixture.model.messages.last?.text == "First tail") }
    }

    @Test func toolResultsAndValidatedSourcesContinueTheConversation() async throws {
        let source = Self.source("a")
        let call = AIToolCall(id: "read-1", namespace: "tern", name: "read_thread", arguments: "{}")
        let provider = AssistantProviderFixture(replies: [.complete(Self.callResponse(call)), .complete(Self.answer("The deadline is Friday."))])
        let fixture = try Fixture(provider: provider, execute: { _ in
            .init(data: .object(["body": .string("Send the proposal Friday."), "source_id": .string(source.id)]), sources: [source])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("What do I owe?")
        await fixture.model.waitForCurrentTurn()

        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.sources == [source])
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests[1].input.contains { $0["type"]?.stringValue == "function_call_output" && $0["call_id"]?.stringValue == "read-1" })
        #expect(try requests[1].input.last?.jsonString().contains("Send the proposal Friday.") == true)
    }

    @Test func readyConnectionLearnsEnabledAccountsAndSuppliesOnlyTheCurrentSenderStyle() async throws {
        var sampledAccounts: [String] = []
        let style = AssistantWritingStyleModel(store: MemoryAssistantWritingStyleStore(), readSamples: { account, authorized in
            #expect(await authorized())
            sampledAccounts.append(account.id)
            return .init(accountID: account.id, requestedCount: 100, selectedCount: 5, inspectedCount: 5,
                samples: (0..<5).map { .init(messageID: "sample-\($0)", date: .now, text: account.id, truncated: false) },
                skippedCount: 0, failures: [], truncated: false, hasMoreSentMail: false)
        }, analyze: { samples, _, date in
            try .init(sampleCount: samples.count, profiledAt: date,
                traits: .init(formality: samples.first == "a" ? .formal : .informal, directness: .direct, detail: .brief))
        })
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("First answer.")), .complete(Self.answer("Second answer."))])
        let fixture = try Fixture(provider: provider, restoredAccountIDs: ["a", "b"], writingStyle: style)
        defer { fixture.clean() }
        #expect(sampledAccounts.isEmpty)
        await fixture.model.refreshConnection()
        await style.waitForLearning()
        #expect(sampledAccounts == ["a", "b"])
        let explicitRequest = "Draft a reply, but use a playful style for this message."
        fixture.model.send(explicitRequest)
        await fixture.model.waitForCurrentTurn()
        fixture.context.currentAccounts = ["b"]
        fixture.model.refreshAccess()
        fixture.model.startChatWithCurrentScope()
        fixture.model.send("Draft for this account.")
        await fixture.model.waitForCurrentTurn()

        let requests = await provider.requests
        #expect(requests.count == 2)
        for (request, id) in zip(requests, ["a", "b"]) {
            let lastLine = try #require(request.instructions.split(separator: "\n").last)
            let rows = try #require(AIJSON.decode(Data(lastLine.utf8)).arrayValue)
            #expect(rows.count == 1)
            #expect(rows.first?["account_id"]?.stringValue == id)
            let profile = try #require(style.round(accountIDs: [id], requestID: UUID()).hints[id]?.profile)
            #expect(rows.first?["preferences"]?.stringValue == (try profile.promptContext()))
            #expect(request.instructions.contains("override an explicit user request about style"))
        }
        #expect(requests.first?.input.first?["content"]?.stringValue == explicitRequest)
        #expect(sampledAccounts == ["a", "b"])
    }

    @Test func navigationKeepsUnfinishedWorkWithoutWideningConversationAccess() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Private answer.")), .complete(Self.answer("Follow-up."))])
        let fixture = try Fixture(provider: provider, restoredAccountIDs: ["a", "b"])
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Private account question")
        await fixture.model.waitForCurrentTurn()
        fixture.model.composerText = "Unfinished follow-up"
        fixture.context.currentAccounts = ["b"]
        fixture.model.refreshAccess()
        #expect(fixture.model.hasPendingScopeChange)
        #expect(fixture.model.messages.count == 2)
        #expect(fixture.model.composerText == "Unfinished follow-up")
        fixture.model.send("Must wait for scope choice")
        #expect(await provider.requests.count == 1)

        fixture.model.keepConversationScope()
        fixture.model.send(fixture.model.composerText)
        await fixture.model.waitForCurrentTurn()
        let request = try #require(await provider.requests.last)
        #expect(request.instructions.contains("a@example.invalid"))
        #expect(!request.instructions.contains("b@example.invalid"))
        #expect(try AIJSON.array(request.input).jsonString().contains("Private account question"))
        #expect(fixture.model.usesPreviousMailScope)

        fixture.model.setAccountEnabled("a", enabled: false)
        #expect(fixture.model.messages.isEmpty)
        #expect(fixture.model.composerText.isEmpty)
    }

    @Test func choosingNewScopeKeepsThePromptAndDiscardsEarlierProviderHistory() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Private answer.")), .complete(Self.answer("New answer."))])
        let fixture = try Fixture(provider: provider, restoredAccountIDs: ["a", "b"])
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Private account question")
        await fixture.model.waitForCurrentTurn()
        fixture.model.composerText = "Unfinished question"
        fixture.context.currentAccounts = ["b"]
        fixture.model.refreshAccess()
        fixture.model.startChatWithCurrentScope()
        #expect(fixture.model.messages.isEmpty)
        #expect(fixture.model.composerText == "Unfinished question")
        #expect(!fixture.model.hasPendingScopeChange)
        fixture.model.send(fixture.model.composerText)
        await fixture.model.waitForCurrentTurn()
        let request = try #require(await provider.requests.last)
        #expect(request.input.count == 1)
        #expect(request.instructions.contains("b@example.invalid"))
        #expect(!request.instructions.contains("a@example.invalid"))
        #expect(try AIJSON.array(request.input).jsonString().contains("Private") == false)
    }

    @Test func navigationCancelsAnActiveTurnAndRetainsItsDraft() async throws {
        let provider = AssistantProviderFixture(replies: [.suspended])
        let fixture = try Fixture(provider: provider, restoredAccountIDs: ["a", "b"])
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("First request")
        await provider.waitForRequests(1)
        let completion = Task { await fixture.model.waitForCurrentTurn() }
        await Task.yield()
        fixture.model.composerText = "Next question"
        fixture.context.currentAccounts = ["b"]
        fixture.model.refreshAccess()
        await provider.release(Self.answer("Late private response"))
        await completion.value
        #expect(!fixture.model.isRunning)
        #expect(fixture.model.hasPendingScopeChange)
        #expect(fixture.model.composerText == "Next question")
        #expect(fixture.model.messages.last?.state == .cancelled)
        #expect(fixture.model.messages.last?.text.contains("Late private response") == false)
    }

    @Test func savedModelDoesNotClaimReadinessAfterCatalogueFailureAndRetryRestoresIt() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Ready again."))])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        #expect(fixture.model.isModelReady)
        await provider.setModelsUnavailable(true)
        await fixture.model.refreshConnection()
        #expect(fixture.model.selectedModelID == "test")
        #expect(!fixture.model.isModelReady)
        #expect(fixture.model.modelErrorMessage != nil)
        fixture.model.composerText = "Keep this question"
        fixture.model.send(fixture.model.composerText)
        #expect(await provider.requests.isEmpty)
        #expect(fixture.model.composerText == "Keep this question")
        await provider.setModelsUnavailable(false)
        await fixture.model.refreshConnection()
        #expect(fixture.model.isModelReady)
        fixture.model.send(fixture.model.composerText)
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.last?.state == .completed)
    }

    @Test func sourceAuthorizationRejectsRevokeAndRegrantButIgnoresNavigation() throws {
        let provider = AssistantProviderFixture(replies: [])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        let authorization = try #require(fixture.model.sourceNavigationAuthorization(accountID: "a"))
        fixture.context.currentAccounts = ["b"]
        fixture.model.refreshAccess()
        #expect(authorization())
        fixture.model.setAccountEnabled("a", enabled: false)
        fixture.model.setAccountEnabled("a", enabled: true)
        #expect(!authorization())
        #expect(fixture.model.sourceNavigationAuthorization(accountID: "a")?() == true)
    }

    @Test func revokingAnAccountClearsDisplayAndProviderHistory() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Private answer.")), .complete(Self.answer("New account answer."))])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Private account question")
        await fixture.model.waitForCurrentTurn()
        fixture.model.composerText = "Private draft prompt"

        fixture.model.setAccountEnabled("a", enabled: false)
        #expect(fixture.model.messages.isEmpty)
        #expect(fixture.model.composerText.isEmpty)
        fixture.model.setAccountEnabled("b", enabled: true)
        fixture.context.currentAccounts = ["b"]
        fixture.model.refreshAccess()
        fixture.model.send("New account question")
        await fixture.model.waitForCurrentTurn()

        let last = try #require(await provider.requests.last)
        #expect(last.input.count == 1)
        #expect(try AIJSON.array(last.input).jsonString().contains("Private") == false)
        #expect(last.instructions.contains("b@example.invalid"))
        #expect(!last.instructions.contains("a@example.invalid"))
    }

    @Test func effectiveAccountScopeIgnoresUnrelatedSelectionChanges() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Answer."))])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Question")
        await fixture.model.waitForCurrentTurn()
        fixture.context.selectedThreads = [.init(accountID: "a", threadID: "other")]
        fixture.model.refreshAccess()
        #expect(fixture.model.messages.count == 2)

        fixture.context.revision += 1
        fixture.model.refreshAccess()
        #expect(fixture.model.messages.isEmpty)
        #expect(fixture.model.models.isEmpty)
    }

    @Test func restoredAccountOptInsSurviveUntilTheMailboxLoads() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Ready."))])
        let fixture = try Fixture(provider: provider, accountsReady: false, restoredAccountIDs: ["a", "removed"])
        defer { fixture.clean() }

        // A hosted MainView can create the real coordinator before AppModel has
        // opened any mailbox. Its refresh must leave the same preferences intact.
        let loadingApp = AppModel()
        let loadingModel = AssistantModel(app: loadingApp, connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
                                          provider: provider, defaults: fixture.defaults)
        loadingModel.refreshAccess()
        #expect(loadingModel.enabledAccountIDs == ["a", "removed"])

        await fixture.model.refreshConnection()
        #expect(fixture.model.enabledAccountIDs == ["a", "removed"])
        #expect(fixture.defaults.stringArray(forKey: "assistant.enabledAccounts") == ["a", "removed"])
        fixture.model.send("Read while loading")
        #expect(!fixture.model.isRunning)
        #expect(await provider.requests.isEmpty)

        fixture.context.isAccountListReady = true
        fixture.model.refreshAccess()
        #expect(fixture.model.enabledAccountIDs == ["a"])
        #expect(fixture.defaults.stringArray(forKey: "assistant.enabledAccounts") == ["a"])
        fixture.model.send("Read now")
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.last?.state == .completed)

        fixture.model.setAccountEnabled("a", enabled: false)
        #expect(fixture.model.enabledAccountIDs.isEmpty)
        #expect(fixture.defaults.stringArray(forKey: "assistant.enabledAccounts") == [])
    }

    @Test func defaultHostedPreferencesCannotChangeStandardDefaults() throws {
        try #require(AssistantRuntimeEnvironment.isTestHost)
        let standard = UserDefaults.standard
        let originalAccounts = standard.stringArray(forKey: "assistant.enabledAccounts")
        let originalModel = standard.string(forKey: "assistant.selectedModel")
        let app = AppModel()
        let context = Context()
        let provider = AssistantProviderFixture(replies: [])
        let model = AssistantModel(app: app, provider: provider, context: { context.value() })
        #expect(model.enabledAccountIDs.isEmpty)
        #expect(model.selectedModelID.isEmpty)
        model.setAccountEnabled("a", enabled: true)
        model.selectedModelID = "isolated-hosted-model"
        model.refreshAccess()
        #expect(model.enabledAccountIDs == ["a"])

        let second = AssistantModel(app: app, provider: provider, context: { context.value() })
        #expect(second.enabledAccountIDs.isEmpty)
        #expect(second.selectedModelID.isEmpty)
        model.setAccountEnabled("a", enabled: false)
        let standardWasChanged = originalAccounts != standard.stringArray(forKey: "assistant.enabledAccounts")
            || originalModel != standard.string(forKey: "assistant.selectedModel")
        #expect(!standardWasChanged)
    }

    @Test func cancellationAndRevocationRejectLateStreamEvents() async throws {
        let provider = AssistantProviderFixture(replies: [.suspended, .suspended])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Read this")
        await provider.waitForRequests(1)
        fixture.model.stop()
        await provider.release(Self.answer("Late text"))
        #expect(fixture.model.messages.last?.state == .cancelled)
        #expect(fixture.model.messages.last?.text != "Late text")

        fixture.model.send("Read again")
        await provider.waitForRequests(2)
        fixture.context.instances = [:]
        fixture.model.refreshAccess()
        await provider.release(Self.answer("Excluded text"))
        #expect(fixture.model.messages.isEmpty)
        #expect(!fixture.model.isRunning)
    }

    @Test func interruptedStreamNeverCompletesTheMessage() async throws {
        let provider = AssistantProviderFixture(replies: [.interrupted("Partial answer")])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Question")
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.last?.text == "Partial answer")
        #expect(fixture.model.messages.last?.state == .failed)
        #expect(fixture.model.errorMessage != nil)
        let messageID = try #require(fixture.model.messages.last?.id)
        #expect(fixture.model.canRetry(messageID))
        fixture.model.setAccountEnabled("a", enabled: false)
        #expect(!fixture.model.canRetry(messageID))
        fixture.model.retry(messageID)
        #expect(fixture.model.messages.isEmpty)
        #expect(await provider.requests.count == 1)
    }

    @Test func defaultScopeSearchesAllEnabledAccountsAndExcludesRevokedAccounts() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Both accounts.")), .complete(Self.answer("One account."))])
        let fixture = try Fixture(provider: provider, restoredAccountIDs: ["a", "b"], initialScope: nil)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        #expect(fixture.model.selectedScope == .allEnabledAccounts)
        #expect(fixture.model.suggestions.first == .awaitingReplies)
        fixture.model.run(.awaitingReplies)
        await fixture.model.waitForCurrentTurn()
        let first = try #require(await provider.requests.first)
        #expect(first.instructions.contains("a@example.invalid"))
        #expect(first.instructions.contains("b@example.invalid"))
        #expect(first.instructions.contains("\"selected_threads\":null"))

        fixture.model.setAccountEnabled("b", enabled: false)
        fixture.context.currentAccounts = ["b"]
        fixture.context.selectedThreads = []
        fixture.model.newChat()
        #expect(fixture.model.selectedScope == .allEnabledAccounts)
        fixture.model.run(.followUps)
        await fixture.model.waitForCurrentTurn()
        let second = try #require(await provider.requests.last)
        #expect(second.instructions.contains("a@example.invalid"))
        #expect(!second.instructions.contains("b@example.invalid"))
        #expect(fixture.model.enabledAccountIDs == ["a"])
        #expect(await provider.requests.count == 2)

        fixture.model.selectedScope = .currentAccount
        fixture.model.newChat()
        #expect(fixture.model.selectedScope == .currentAccount)
    }

    @Test func contextualSuggestionsUseOnlySelectedMailWithinTheActiveScope() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Summary."))])
        let fixture = try Fixture(provider: provider, restoredAccountIDs: ["a", "b"], initialScope: nil)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        #expect(fixture.model.contextualSuggestions == [.summarizeThread, .draftReply])
        fixture.context.selectedThreads.insert(.init(accountID: "b", threadID: "other"))
        #expect(fixture.model.contextualSuggestions == [.summarizeThread])
        #expect(!fixture.model.canRun(.draftReply))
        fixture.model.selectedScope = .currentAccount
        #expect(fixture.model.contextualSuggestions.isEmpty)
        #expect(!fixture.model.canRun(.summarizeThread))

        fixture.context.selectedThreads = [.init(accountID: "a", threadID: "t")]
        fixture.model.run(.summarizeThread)
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.selectedScope == .selectedThreads)
        let request = try #require(await provider.requests.first)
        #expect(request.instructions.contains("\"thread_id\":\"t\""))
        #expect(!request.instructions.contains("b@example.invalid"))

        fixture.context.selectedThreads = []
        #expect(fixture.model.contextualSuggestions.isEmpty)
        #expect(!fixture.model.canRun(.summarizeThread))
    }

    @Test(arguments: [AssistantSuggestion.awaitingReplies, .tasksFromMail, .eventsFromMail, .priorities, .followUps, .recentMail])
    func suggestionsSendImmediatelyWithoutWideningTheActiveScope(_ suggestion: AssistantSuggestion) async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Selected priorities.")), .complete(Self.answer("Awaiting replies."))])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        fixture.model.selectedScope = .selectedThreads
        await fixture.model.refreshConnection()
        #expect(fixture.model.canRun(suggestion))
        fixture.model.run(suggestion)
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.selectedScope == .selectedThreads)
        #expect(fixture.model.messages.first?.isUser == true)
        let first = try #require(await provider.requests.first)
        #expect(first.input.first?["content"]?.stringValue?.contains("selected conversations") == true)
        #expect(!first.instructions.contains("\"selected_threads\":null"))

        fixture.context.selectedThreads = []
        fixture.model.refreshAccess()
        #expect(!fixture.model.canRun(suggestion))
        #expect(fixture.model.requirement(for: suggestion) != nil)
        fixture.model.run(suggestion)
        #expect(await provider.requests.count == 1)

        fixture.model.selectedScope = .currentAccount
        fixture.model.startChatWithCurrentScope()
        fixture.model.run(suggestion)
        await fixture.model.waitForCurrentTurn()
        let second = try #require(await provider.requests.last)
        #expect(second.instructions.contains("\"selected_threads\":null"))
        #expect(!second.instructions.contains("b@example.invalid"))
        #expect(fixture.model.enabledAccountIDs == ["a"])
        fixture.context.currentAccounts = ["b"]
        fixture.model.refreshAccess()
        fixture.model.run(suggestion)
        #expect(await provider.requests.count == 2)
        #expect(fixture.model.enabledAccountIDs == ["a"])
    }

    @Test func structuredResultsSurviveAnEmptyAnswerAndLoseActionsWhenAccessChanges() async throws {
        let source = Self.source("a")
        let evidence = "Send the proposal by November 6. Meet on November 9 at 10:00 UTC."
        let read = AIToolCall(id: "read", namespace: "tern", name: "read_thread", arguments: "{}")
        let tasks = AIToolCall(id: "tasks", namespace: "tern", name: "present_tasks", arguments: try AIJSON.object([
            "tasks": .array([.object(["source_id": .string(source.id), "title": .string("Send the proposal"),
                "owner": .null, "notes": .null, "due_date": .string("2026-11-06"), "evidence": .string(evidence)])])
        ]).jsonString())
        let events = AIToolCall(id: "events", namespace: "tern", name: "present_events", arguments: try AIJSON.object([
            "events": .array([.object(["source_id": .string(source.id), "proposal": .object([
                "title": .string("Proposal meeting"), "start": .string("2026-11-09T10:00:00Z"),
                "end": .null, "all_day": .bool(false), "time_zone": .string("UTC"),
                "location": .null, "notes": .null, "evidence": .string(evidence), "uncertainties": .array([])
            ])])])
        ]).jsonString())
        // Reads and presentation may share one provider batch; only accepted
        // read results can back subsequent cards.
        let calls = [read, tasks, events]
        let response = AIResponse(output: calls.flatMap { Self.callResponse($0).output }, text: "", toolCalls: calls)
        let provider = AssistantProviderFixture(replies: [.complete(response), .complete(Self.emptyAnswer())])
        var underlyingCalls: [String] = []
        let fixture = try Fixture(provider: provider, execute: { call in
            underlyingCalls.append(call.name)
            return .init(data: .object(["account_id": .string("a"), "thread_id": .string("t"),
                "messages": .array([.object(["message_id": .string("m"), "thread_id": .string("t"), "text": .string(evidence)])])]),
                sources: [source])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Show my tasks and events")
        await fixture.model.waitForCurrentTurn()
        let message = try #require(fixture.model.messages.last)
        #expect(message.state == .completed)
        #expect(underlyingCalls == ["read_thread"])
        #expect(message.taskResults.count == 1)
        #expect(message.eventResults.count == 1)
        #expect(message.calendarProposals.isEmpty)
        let task = try #require(message.taskResults.first)
        let event = try #require(message.eventResults.first)
        #expect(fixture.model.canUseTaskResult(task))
        #expect(fixture.model.canUseEventResult(event))
        #expect(task.request.source?.messageID == "m")
        #expect(event.canAddToCalendar)
        fixture.context.revision += 1
        #expect(!fixture.model.canUseTaskResult(task))
        #expect(!fixture.model.canUseEventResult(event))
        fixture.model.refreshAccess()
        #expect(fixture.model.messages.isEmpty)
    }

    @Test func onlyExplicitlyPresentedEmailsBecomeOrderedCards() async throws {
        let search = AIToolCall(id: "search", namespace: "tern", name: "search_mail", arguments: "{}")
        let present = AIToolCall(id: "present", namespace: "tern", name: "present_emails", arguments: "{}")
        let calls = [search, present]
        let response = AIResponse(output: calls.flatMap { Self.callResponse($0).output }, text: "", toolCalls: calls)
        let provider = AssistantProviderFixture(replies: [.complete(response), .complete(Self.answer("These two need a reply."))])
        let first = Self.email("a", thread: "first")
        let second = Self.email("a", thread: "second")
        let unused = Self.email("a", thread: "unused")
        let fixture = try Fixture(provider: provider, execute: { call in
            if call.name == "search_mail" {
                return .init(data: .null, sources: [first.source, second.source, unused.source])
            }
            return .init(data: .null, sources: [second.source, first.source], emailResults: [second, first])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Which messages need a reply?")
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.last?.emailResults.map(\.id) == [second.id, first.id])
        #expect(fixture.model.messages.last?.sources.count == 3)
        fixture.model.setAccountEnabled("a", enabled: false)
        #expect(fixture.model.messages.isEmpty)
    }

    @Test(arguments: ["present_tasks", "present_emails"])
    func smallerPresentationRetriesRetainTaskAndEmailCards(toolName: String) async throws {
        let source = Self.source("a")
        let evidence = "Send the proposal. Confirm the date. Review the budget."
        let titles = ["Send the proposal", "Confirm the date", "Review the budget"]
        let emails = (0..<3).map { Self.email("a", thread: "priority-\($0)") }
        let reads = (0..<6).map { AIToolCall(id: "read-\($0)", namespace: "tern", name: "read_thread", arguments: "{}") }
        func presentation(_ id: String, indices: [Int], updated: Bool = false, invalid: Bool = false) throws -> AIToolCall {
            let rows = indices.map { index -> AIJSON in
                if toolName == "present_emails" {
                    return .object(["source_id": .string(emails[index].source.id),
                                    "reason": .string(updated && index == 0 ? "Updated reason" : "Needs review")])
                }
                return .object(["source_id": .string(source.id), "title": .string(titles[index]),
                    "owner": .null, "notes": updated && index == 0 ? .string("Updated details") : .null,
                    "due_date": .null, "evidence": .string(invalid ? "Evidence that was not read." : evidence)])
            }
            let key = toolName == "present_emails" ? "emails" : "tasks"
            return .init(id: id, namespace: "tern", name: toolName,
                         arguments: try AIJSON.object([key: .array(rows)]).jsonString())
        }
        let first = try presentation("first", indices: [0])
        let second = try presentation("second", indices: [1])
        let invalid = try presentation("invalid", indices: [2], invalid: true)
        let repair = try presentation("repair", indices: [0, 2], updated: true)
        let initial = [first, second, invalid]
        let batch = AIResponse(output: initial.flatMap { Self.callResponse($0).output }, text: "", toolCalls: initial)
        var replies = reads.map { AssistantProviderFixture.Reply.complete(Self.callResponse($0)) }
        replies += [.complete(batch), .complete(Self.callResponse(repair)), .complete(Self.answer("Three suggestions are ready to review."))]
        let provider = AssistantProviderFixture(replies: replies)
        var underlyingCalls: [String] = []
        let fixture = try Fixture(provider: provider, execute: { call in
            underlyingCalls.append(call.name)
            if call.name == "present_emails" {
                if call.id == "invalid" { throw MailAssistantTools.ToolError.invalidArguments }
                let indices = call.id == "first" ? [0] : call.id == "second" ? [1] : [0, 2]
                let cards = indices.map { index -> AssistantEmailResult in
                    var card = emails[index]
                    card.reason = call.id == "repair" && index == 0 ? "Updated reason" : "Needs review"
                    return card
                }
                return .init(data: .null, sources: cards.map(\.source), emailResults: cards)
            }
            return .init(data: .object(["account_id": .string("a"), "thread_id": .string("t"),
                "messages": .array([.object(["message_id": .string("m"), "thread_id": .string("t"), "text": .string(evidence)])])]),
                sources: [source])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Show the suggestions I should review")
        await fixture.model.waitForCurrentTurn()

        let requests = await provider.requests
        #expect(requests.count == AssistantModel.maximumRounds + 1)
        #expect(requests[7].tools.map(\.name) == [toolName])
        #expect(requests[8].tools.isEmpty)
        let message = try #require(fixture.model.messages.last)
        #expect(message.state == .completed)
        if toolName == "present_emails" {
            #expect(message.emailResults.map(\.id) == emails.map(\.id))
            #expect(message.emailResults.first?.reason == "Updated reason")
            #expect(message.taskResults.isEmpty)
        } else {
            #expect(message.taskResults.map(\.title) == titles)
            #expect(message.taskResults.first?.notes == "Updated details")
            #expect(message.emailResults.isEmpty)
            let task = try #require(message.taskResults.first)
            #expect(fixture.model.canUseTaskResult(task))
        }
        #expect(underlyingCalls.allSatisfy { $0 == "read_thread" || $0 == "present_emails" })
        #expect(message.calendarProposals.isEmpty)
        #expect(message.draftIDs.isEmpty)
        #expect(fixture.model.errorMessage == nil)
    }

    @Test func presentedCardCannotExposeAnotherAccountsMetadata() async throws {
        let call = AIToolCall(id: "present", namespace: "tern", name: "present_emails", arguments: "{}")
        let provider = AssistantProviderFixture(replies: [.complete(Self.callResponse(call)), .complete(Self.answer("I could not show that conversation."))])
        let fixture = try Fixture(provider: provider, execute: { _ in
            .init(data: .string("Private-card"), emailResults: [Self.email("b", thread: "private")])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Show my mail")
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.last?.emailResults.isEmpty == true)
        let resumed = try #require(await provider.requests.last)
        #expect(try AIJSON.array(resumed.input).jsonString().contains("Private-card") == false)
    }

    @Test func readingRoundsLeaveRoomForCardsAndAnAnswer() async throws {
        let reads = (0..<6).map { AIToolCall(id: "read-\($0)", namespace: "tern", name: $0 == 0 ? "search_mail" : "read_thread", arguments: "{}") }
        let present = AIToolCall(id: "present", namespace: "tern", name: "present_emails", arguments: "{}")
        var replies = reads.map { AssistantProviderFixture.Reply.complete(Self.callResponse($0)) }
        replies += [.complete(Self.callResponse(present)), .complete(Self.answer("This conversation needs attention. I reviewed a limited selection."))]
        let provider = AssistantProviderFixture(replies: replies)
        let email = Self.email("a", thread: "t")
        var executions = 0
        let fixture = try Fixture(provider: provider, execute: { call in
            executions += 1
            return .init(data: .null, sources: [email.source], emailResults: call.name == "present_emails" ? [email] : [])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("What needs my attention?")
        await fixture.model.waitForCurrentTurn()
        let requests = await provider.requests
        #expect(requests.count == AssistantModel.maximumRounds)
        #expect(Set(requests[6].tools.map(\.name)) == ["present_emails", "present_tasks", "present_events"])
        #expect(requests[7].tools.isEmpty)
        #expect(executions == 7)
        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.emailResults == [email])
        #expect(fixture.model.errorMessage == nil)
    }

    @Test func excessToolCallsAreCheckpointedWithoutActionsBeforeFinalizing() async throws {
        let draft = AIToolCall(id: "saved", namespace: "tern", name: "prepare_draft", arguments: "{}")
        let reads = (0..<22).map { AIToolCall(id: "read-\($0)", namespace: "tern", name: "read_thread", arguments: "{}") }
        let lateDrafts = (0..<2).map { AIToolCall(id: "late-\($0)", namespace: "tern", name: "prepare_draft", arguments: "{}") }
        let calls = [draft] + reads + lateDrafts
        let present = (0..<4).map { AIToolCall(id: "present-\($0)", namespace: "tern", name: "present_emails", arguments: "{}") }
        func batch(_ calls: [AIToolCall]) -> AIResponse {
            .init(output: calls.flatMap { Self.callResponse($0).output }, text: "", toolCalls: calls)
        }
        let provider = AssistantProviderFixture(replies: [.complete(batch(calls)), .complete(batch(present)), .complete(Self.answer("The first draft is ready. The remaining operations were not run."))])
        let email = Self.email("a", thread: "t")
        var executions = 0
        var draftCount = 0
        let fixture = try Fixture(provider: provider, execute: { call in
            executions += 1
            if call.id == "read-18" { throw AttachmentTextReader.ReadError.noPDFText }
            if call.name == "prepare_draft" {
                draftCount += 1
                return .init(data: .object(["draft_id": .string("saved-draft")]), createdDraftID: "saved-draft")
            }
            return .init(data: .null, sources: [email.source], emailResults: call.name == "present_emails" ? [email] : [])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Read these conversations and prepare drafts")
        await fixture.model.waitForCurrentTurn()
        let requests = await provider.requests
        #expect(requests.count == 3)
        #expect(Set(requests[1].tools.map(\.name)) == ["present_emails", "present_tasks", "present_events"])
        #expect(requests[2].tools.isEmpty)
        #expect(executions == AssistantModel.maximumToolCalls - 1)
        #expect(draftCount == 1)
        let outputs = requests[2].input.filter { $0["type"]?.stringValue == "function_call_output" }
        #expect(Set(outputs.compactMap { $0["call_id"]?.stringValue }) == Set((calls + present).map(\.id)))
        for id in ["read-19", "read-20", "read-21", "late-0", "late-1", "present-3"] {
            let output = try #require(outputs.first { $0["call_id"]?.stringValue == id }?["output"]?.stringValue)
            #expect(try AIJSON.decode(Data(output.utf8))["status"]?.stringValue == "not_run")
        }
        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.draftIDs == ["saved-draft"])
        #expect(fixture.model.messages.last?.emailResults == [email])
    }

    @Test func anEarlyPresentationFailureCanReadItsMissingSourceBeforeRetrying() async throws {
        let source = Self.source("a")
        let evidence = "Meet on November 9 at 10:00 UTC."
        let arguments = try AIJSON.object(["events": .array([.object([
            "source_id": .string(source.id), "proposal": .object([
                "title": .string("Planning meeting"), "start": .string("2026-11-09T10:00:00Z"),
                "end": .null, "all_day": .bool(false), "time_zone": .string("UTC"),
                "location": .null, "notes": .null, "evidence": .string(evidence), "uncertainties": .array([])
            ])
        ])])]).jsonString()
        let unread = AIToolCall(id: "unread", namespace: "tern", name: "present_events", arguments: arguments)
        let read = AIToolCall(id: "read", namespace: "tern", name: "read_thread", arguments: "{}")
        let retry = AIToolCall(id: "retry", namespace: "tern", name: "present_events", arguments: arguments)
        let provider = AssistantProviderFixture(replies: [
            .complete(Self.callResponse(unread)), .complete(Self.callResponse(read)),
            .complete(Self.callResponse(retry)), .complete(Self.answer("The event is ready to review."))
        ])
        var underlyingCalls: [String] = []
        let fixture = try Fixture(provider: provider, execute: { call in
            underlyingCalls.append(call.name)
            return .init(data: .object(["account_id": .string("a"), "thread_id": .string("t"),
                "messages": .array([.object(["message_id": .string("m"), "thread_id": .string("t"), "text": .string(evidence)])])]),
                sources: [source])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Show my upcoming events")
        await fixture.model.waitForCurrentTurn()

        let requests = await provider.requests
        #expect(requests.count == 4)
        #expect(requests[1].tools.contains { $0.name == "read_thread" })
        let output = try #require(requests[1].input.last?["output"]?.stringValue)
        #expect(try AIJSON.decode(Data(output.utf8))["error"]?.stringValue == AssistantResultTools.ToolError.unreadSource.localizedDescription)
        #expect(underlyingCalls == ["read_thread"])
        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.eventResults.map(\.title) == ["Planning meeting"])
        #expect(fixture.model.messages.last?.calendarProposals.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func failedEventPresentationGetsOneRepairAtTheBudgetLimit(repairSucceeds: Bool) async throws {
        let source = Self.source("a")
        let evidence = "Meet on November 8 and 9 at 10:00 UTC. Another meeting has no date yet."
        let reads = (0..<20).map { AIToolCall(id: "read-\($0)", namespace: "tern", name: "read_thread", arguments: "{}") }
        func proposal(_ title: String, start: String? = "2026-11-09T10:00:00Z", notes: String? = nil) -> AIJSON {
            .object(["source_id": .string(source.id), "proposal": .object([
                "title": .string(title), "start": start.map(AIJSON.string) ?? .null, "end": .null,
                "all_day": .bool(false), "time_zone": .string("UTC"), "location": .null,
                "notes": notes.map(AIJSON.string) ?? .null,
                "evidence": .string(evidence), "uncertainties": .array([])
            ])])
        }
        func presentation(_ id: String, _ rows: [AIJSON]) throws -> AIToolCall {
            .init(id: id, namespace: "tern", name: "present_events",
                  arguments: try AIJSON.object(["events": .array(rows)]).jsonString())
        }
        func batch(_ calls: [AIToolCall]) -> AIResponse {
            .init(output: calls.flatMap { Self.callResponse($0).output }, text: "", toolCalls: calls)
        }
        let invalid = proposal("Third meeting", start: "2026-11-08T10:00:00")
        let presentations = try [
            presentation("first", [proposal("First meeting", start: nil)]),
            presentation("second", [proposal("Second meeting")]),
            presentation("invalid", [invalid])
        ]
        let repair = try presentation("repair", repairSucceeds
            ? [proposal("First meeting", start: nil, notes: "Reviewed details"), proposal("Third meeting", start: "2026-11-08T10:00:00Z")]
            : [invalid])
        var replies: [AssistantProviderFixture.Reply] = [.complete(batch(Array(reads.prefix(15))))]
        replies += reads.suffix(5).map { .complete(Self.callResponse($0)) }
        replies += [.complete(batch(presentations)), .complete(Self.callResponse(repair)),
                    .complete(Self.answer(repairSucceeds ? "Three events are ready to review." : "Two events are ready to review. Another could not be displayed."))]
        let provider = AssistantProviderFixture(replies: replies)
        var underlyingCalls: [String] = []
        let fixture = try Fixture(provider: provider, execute: { call in
            underlyingCalls.append(call.name)
            return .init(data: .object(["account_id": .string("a"), "thread_id": .string("t"),
                "messages": .array([.object(["message_id": .string("m"), "thread_id": .string("t"), "text": .string(evidence)])])]),
                sources: [source])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Show my upcoming events")
        await fixture.model.waitForCurrentTurn()

        let requests = await provider.requests
        #expect(requests.count == AssistantModel.maximumRounds + 1)
        #expect(Set(requests[6].tools.map(\.name)) == ["present_emails", "present_tasks", "present_events"])
        #expect(requests[7].tools.map(\.name) == ["present_events"])
        #expect(requests[8].tools.isEmpty)
        let failedOutput = requests[7].input.first {
            $0["type"]?.stringValue == "function_call_output" && $0["call_id"]?.stringValue == "invalid"
        }
        let errorOutput = try #require(failedOutput?["output"]?.stringValue)
        let validationError = try #require(AIJSON.decode(Data(errorOutput.utf8))["error"]?.stringValue)
        #expect(validationError != "This operation did not complete. Narrow the request or explain the limitation to the user.")
        #expect(!validationError.isEmpty)
        let outputs = requests[8].input.filter { $0["type"]?.stringValue == "function_call_output" }
        #expect(outputs.count == AssistantModel.maximumToolCalls)
        let outputIDs = Set(outputs.compactMap { $0["call_id"]?.stringValue })
        let executedCalls = reads + presentations + [repair]
        let expectedIDs = Set(executedCalls.map(\.id))
        #expect(outputIDs == expectedIDs)
        #expect(underlyingCalls == Array(repeating: "read_thread", count: reads.count))
        let message = try #require(fixture.model.messages.last)
        #expect(message.state == .completed)
        #expect(message.eventResults.map(\.title) == (repairSucceeds ? ["Third meeting", "Second meeting", "First meeting"] : ["Second meeting", "First meeting"]))
        #expect(message.eventResults.last?.event.description == (repairSucceeds ? "Reviewed details" : nil))
        let datedCardsAreActionable = message.eventResults.dropLast().allSatisfy { $0.canAddToCalendar }
        #expect(datedCardsAreActionable)
        #expect(message.eventResults.last?.canAddToCalendar == false)
        #expect(message.calendarProposals.isEmpty)
        #expect(message.draftIDs.isEmpty)
        #expect(fixture.model.errorMessage == nil)
    }

    @Test func emptyTerminalPreservesEarlierFormattedTextAndCards() async throws {
        let read = AIToolCall(id: "read", namespace: "tern", name: "read_thread", arguments: "{}")
        let present = AIToolCall(id: "present", namespace: "tern", name: "present_emails", arguments: "{}")
        let heading = "## Needs a reply"
        let bullets = "- Review the proposal\n- Confirm the date"
        func response(_ call: AIToolCall, text: String) -> AIResponse {
            .init(output: Self.answer(text).output + Self.callResponse(call).output, text: text, toolCalls: [call])
        }
        let provider = AssistantProviderFixture(replies: [
            .complete(response(read, text: heading)), .complete(response(present, text: bullets)),
            .complete(Self.emptyAnswer()),
        ])
        let email = Self.email("a", thread: "t")
        let fixture = try Fixture(provider: provider, execute: { call in
            .init(data: .null, sources: [email.source], emailResults: call.name == "present_emails" ? [email] : [])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Show the relevant conversations")
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.text == heading + "\n\n" + bullets)
        #expect(fixture.model.messages.last?.emailResults == [email])
        #expect(fixture.model.errorMessage == nil)
        #expect(await provider.requests.count == 3)
    }

    @Test(arguments: [false, true])
    func genuinelyEmptyReplyGetsOneBoundedFinalization(answers: Bool) async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.emptyAnswer()), .complete(Self.emptyAnswer()), .complete(answers ? Self.answer("The available mail does not establish a deadline.") : Self.emptyAnswer())])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("What is the deadline?")
        await fixture.model.waitForCurrentTurn()
        let requests = await provider.requests
        #expect(requests.count == 3)
        #expect(Set(requests[1].tools.map(\.name)) == ["present_emails", "present_tasks", "present_events"])
        #expect(requests[2].tools.isEmpty)
        #expect(fixture.model.messages.last?.state == (answers ? .completed : .failed))
        #expect((fixture.model.errorMessage == nil) == answers)
    }

    @Test func earlierToolPreambleDoesNotCountAsTheFinalAnswer() async throws {
        let read = AIToolCall(id: "read", namespace: "tern", name: "read_thread", arguments: "{}")
        let preamble = "I’ll check your mail now."
        let start = AIResponse(output: Self.answer(preamble).output + Self.callResponse(read).output, text: preamble, toolCalls: [read])
        let answer = "The proposal needs your reply by Friday."
        let provider = AssistantProviderFixture(replies: [
            .complete(start), .complete(Self.emptyAnswer()), .complete(Self.emptyAnswer()), .complete(Self.answer(answer)),
        ])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("What needs my attention?")
        await fixture.model.waitForCurrentTurn()
        let requests = await provider.requests
        #expect(requests.count == 4)
        #expect(Set(requests[2].tools.map(\.name)) == ["present_emails", "present_tasks", "present_events"])
        #expect(requests[3].tools.isEmpty)
        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.text == preamble + "\n\n" + answer)
    }

    @Test func retryKeepsCardsAndDraftsWithoutRepeatingCompletedActions() async throws {
        let draft = AIToolCall(id: "draft", namespace: "tern", name: "prepare_draft", arguments: "{\"body\":\"Original\"}")
        let present = AIToolCall(id: "present", namespace: "tern", name: "present_emails", arguments: "{}")
        let changedDraft = AIToolCall(id: "changed", namespace: "tern", name: "prepare_draft", arguments: "{\"body\":\"Changed wording\",\"subject\":\"New subject\"}")
        let calls = [draft, present]
        let response = AIResponse(output: calls.flatMap { Self.callResponse($0).output }, text: "", toolCalls: calls)
        let provider = AssistantProviderFixture(replies: [
            .complete(response), .interrupted("Partial"), .complete(Self.callResponse(changedDraft)),
            .complete(Self.answer("Your original draft is ready.")),
            .complete(Self.callResponse(changedDraft)), .complete(Self.answer("The new draft is ready.")),
        ])
        let email = Self.email("a", thread: "t")
        var draftsCreated = 0
        let fixture = try Fixture(provider: provider, execute: { call in
            if call.name == "present_emails" { return .init(data: .null, sources: [email.source], emailResults: [email]) }
            draftsCreated += 1
            let draftID = "saved-\(draftsCreated)"
            return .init(data: .object(["draft_id": .string(draftID)]), createdDraftID: draftID)
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Show the conversation and prepare a reply")
        await fixture.model.waitForCurrentTurn()
        let failed = try #require(fixture.model.messages.last)
        #expect(failed.state == .failed)
        #expect(failed.errorMessage != nil)
        fixture.model.retry(failed.id)
        await fixture.model.waitForCurrentTurn()
        #expect(draftsCreated == 1)
        #expect(fixture.model.messages.last?.state == .failed)
        fixture.model.retry(failed.id)
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.count == 2)
        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.errorMessage == nil)
        #expect(fixture.model.messages.last?.emailResults == [email])
        #expect(fixture.model.messages.last?.draftIDs == ["saved-1"])
        #expect(fixture.model.messages.last?.createdAt == failed.createdAt)
        let requests = await provider.requests
        #expect(requests[2].tools.allSatisfy { $0.name != "prepare_draft" })
        #expect(requests[3].tools.allSatisfy { $0.name != "prepare_draft" })
        #expect(requests[3].input.filter { $0["role"]?.stringValue == "user" }.count == 1)
        #expect(requests[3].input.contains { $0["output"]?.stringValue?.contains("saved-1") == true })

        fixture.model.send("Prepare a second draft with the changed wording")
        await fixture.model.waitForCurrentTurn()
        #expect(draftsCreated == 2)
        #expect(fixture.model.messages.last?.state == .completed)
    }

    @Test func completedDraftSurvivesCancellationDuringTheNextTool() async throws {
        let draft = AIToolCall(id: "draft", namespace: "tern", name: "prepare_draft", arguments: "{}")
        let read = AIToolCall(id: "read", namespace: "tern", name: "read_thread", arguments: "{}")
        let calls = [draft, read]
        let response = AIResponse(output: calls.flatMap { Self.callResponse($0).output }, text: "", toolCalls: calls)
        let provider = AssistantProviderFixture(replies: [.complete(response), .complete(Self.answer("Your draft is already prepared."))])
        let pause = ToolPause()
        var draftCount = 0
        let fixture = try Fixture(provider: provider, execute: { call in
            if call.name == "prepare_draft" {
                draftCount += 1
                return .init(data: .object(["draft_id": .string("saved-draft")]), createdDraftID: "saved-draft")
            }
            await pause.wait()
            return .init(data: .null)
        })
        defer { fixture.clean(); pause.release() }
        await fixture.model.refreshConnection()
        fixture.model.send("Prepare a draft, then read the other thread")
        await pause.waitUntilStarted()
        #expect(fixture.model.messages.last?.draftIDs == ["saved-draft"])
        fixture.model.stop()
        pause.release()
        fixture.model.send("Continue")
        await fixture.model.waitForCurrentTurn()

        let requests = await provider.requests
        #expect(requests.count == 2)
        let resumed = try #require(requests.last)
        let outputs = resumed.input.filter { $0["type"]?.stringValue == "function_call_output" }
        #expect(outputs.count == 2)
        #expect(outputs.first?["output"]?.stringValue?.contains("saved-draft") == true)
        #expect(outputs.last?["output"]?.stringValue?.contains("not completed") == true)
        #expect(draftCount == 1)
        #expect(fixture.model.messages.last?.state == .completed)
    }

    @Test func attachmentFailureKeepsItsSpecificLimitation() async throws {
        let call = AIToolCall(id: "pdf", namespace: "tern", name: "read_attachment", arguments: "{}")
        let provider = AssistantProviderFixture(replies: [.complete(Self.callResponse(call)), .complete(Self.answer("This PDF requires OCR."))])
        let fixture = try Fixture(provider: provider, execute: { _ in throw AttachmentTextReader.ReadError.noPDFText })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Read the PDF")
        await fixture.model.waitForCurrentTurn()
        let resumed = try #require(await provider.requests.last)
        #expect(resumed.input.last?["output"]?.stringValue?.contains("OCR is not available") == true)
        #expect(fixture.model.messages.last?.state == .completed)
    }

    @Test(arguments: [false, true])
    func cancelledToolDeliveryIsAcknowledgedOnlyByItsAcceptingTurn(startNewChat: Bool) async throws {
        let first = AIToolCall(id: "abandoned", namespace: "tern", name: "prepare_draft", arguments: "{}")
        let retry = AIToolCall(id: "retry", namespace: "tern", name: "prepare_draft", arguments: "{}")
        let provider = AssistantProviderFixture(replies: [
            .complete(Self.callResponse(first)), .complete(Self.callResponse(retry)),
            .complete(Self.answer("Your draft is prepared.")),
        ])
        var acknowledged: [String] = []
        weak var model: AssistantModel?
        let fixture = try Fixture(provider: provider, acknowledge: { acknowledged.append($0) }, execute: { call in
            if call.id == first.id {
                // Reproduce Stop after a successful tool operation but before its
                // caller resumes, with the next turn already owning the model.
                if startNewChat { model?.newChat() } else { model?.stop() }
                model?.send("Continue")
            }
            return .init(data: .object(["draft_id": .string("saved-draft")]), createdDraftID: "saved-draft")
        })
        defer { fixture.clean() }
        model = fixture.model
        await fixture.model.refreshConnection()
        fixture.model.send("Prepare a draft")
        await provider.waitForRequests(2)
        await fixture.model.waitForCurrentTurn()

        #expect(acknowledged == [retry.id])
        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.draftIDs == ["saved-draft"])
        let requests = await provider.requests
        #expect(requests.count == 3)
        #expect(try AIJSON.array(requests[1].input).jsonString().contains("saved-draft") == false)
        #expect(requests[2].input.last?["output"]?.stringValue?.contains("saved-draft") == true)
        if startNewChat {
            #expect(fixture.model.messages.count == 2)
            #expect(requests[1].input.count == 1)
        } else {
            #expect(fixture.model.messages[1].state == .cancelled)
            #expect(fixture.model.messages[1].draftIDs.isEmpty)
        }
    }

    @Test func invalidNamespaceCannotReachToolExecution() async throws {
        let call = AIToolCall(id: "bad", namespace: "external", name: "read_thread", arguments: "{}")
        let provider = AssistantProviderFixture(replies: [.complete(Self.callResponse(call))])
        var calls = 0
        let fixture = try Fixture(provider: provider, execute: { _ in calls += 1; return .init(data: .null) })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Question")
        await fixture.model.waitForCurrentTurn()
        #expect(calls == 0)
        #expect(fixture.model.messages.last?.state == .failed)
    }

    @Test func structuredSummaryRejectsInventedEvidence() async throws {
        let source = Self.source("a")
        func summary(_ sourceID: String) throws -> String {
            try AIJSON.object([
                "summary": .string("A proposal is due."), "source_ids": .array([.string(sourceID)]),
                "decisions": .array([]), "open_tasks": .array([
                    .object(["description": .string("Send proposal"), "owner": .null,
                             "due_date": .null, "source_ids": .array([.string(sourceID)])])
                ])
            ]).jsonString()
        }
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer(try summary(source.id))), .complete(Self.answer(try summary("invented")))])
        let tools = AssistantToolSession(definitions: [], execute: { _ in .init(data: .object(["source_id": .string(source.id)]), sources: [source]) })
        let service = AssistantSummaryService(provider: provider, model: "test", tools: tools, isScopeValid: { true })
        let value = try await service.summarize(thread: .init(accountID: "a", threadID: "t"))
        #expect(value.openTasks.count == 1)
        #expect(value.openTasks.first?.owner == nil)
        await #expect(throws: AIProviderError.invalidResponse) {
            try await service.summarize(thread: .init(accountID: "a", threadID: "t"))
        }
        #expect(await provider.requests.first?.responseSchema != nil)
    }

    private static func source(_ account: String) -> AssistantSource {
        .init(accountID: account, threadID: "t", messageID: "m", partID: nil, title: "Proposal")
    }
    private static func email(_ account: String, thread: String) -> AssistantEmailResult {
        .init(source: .init(accountID: account, threadID: thread, messageID: nil, partID: nil, title: "Conversation \(thread)"),
              senderName: "Sender", senderEmail: "sender@example.invalid", subject: "Conversation \(thread)",
              snippet: "A question to answer.", date: .distantPast, isUnread: true, isStarred: false,
              messageCount: 2, accountEmail: "\(account)@example.invalid")
    }
    private static func answer(_ text: String) -> AIResponse {
        .init(output: [.object(["type": .string("message"), "role": .string("assistant"), "content": .array([
            .object(["type": .string("output_text"), "text": .string(text)])
        ])])], text: text, toolCalls: [])
    }
    private static func emptyAnswer() -> AIResponse {
        .init(output: [.object(["type": .string("reasoning"), "id": .string("rs_" + UUID().uuidString), "summary": .array([])])],
              text: "", toolCalls: [])
    }
    private static func callResponse(_ call: AIToolCall) -> AIResponse {
        .init(output: [.object(["type": .string("function_call"), "call_id": .string(call.id),
            "namespace": .string(call.namespace), "name": .string(call.name), "arguments": .string(call.arguments)])], text: "", toolCalls: [call])
    }

    @MainActor private final class Context {
        let accounts = ["a", "b"].map { AccountRecord(id: $0, email: "\($0)@example.invalid", displayName: nil, grantedScopes: [], addedAt: .distantPast) }
        var isAccountListReady = true
        var currentAccounts: Set<String> = ["a"]
        var selectedThreads: Set<ThreadKey> = [.init(accountID: "a", threadID: "t")]
        var instances = ["a": "instance-a", "b": "instance-b"]
        var revision = 1
        func value() -> AssistantContext {
            .init(accounts: isAccountListReady ? accounts : [], isAccountListReady: isAccountListReady,
                  currentAccountIDs: currentAccounts, selectedThreads: selectedThreads,
                  accountInstances: isAccountListReady ? instances : [:], connectionRevision: revision, canUsePlan: true)
        }
    }

    @MainActor private struct Fixture {
        let model: AssistantModel
        let context: Context
        let defaults: UserDefaults
        let domain: String

        init(provider: any AIProvider,
             accountsReady: Bool = true, restoredAccountIDs: [String] = [],
             initialScope: AssistantScope? = .currentAccount,
             writingStyle: AssistantWritingStyleModel? = nil,
             acknowledge: @escaping @MainActor (String) -> Void = { _ in },
             execute: @escaping @MainActor (AIToolCall) async throws -> MailAssistantToolResult = { _ in .init(data: .null) }) throws {
            domain = "TernAssistantTests." + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: domain))
            defaults.set(restoredAccountIDs, forKey: "assistant.enabledAccounts")
            let context = Context()
            context.isAccountListReady = accountsReady
            self.context = context
            model = AssistantModel(app: AppModel(), connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
                provider: provider, defaults: defaults, context: { context.value() }, makeTools: { _ in
                    .init(definitions: MailAssistantTools.definitions, acknowledge: acknowledge, execute: execute)
                }, writingStyle: writingStyle)
            if let initialScope { model.selectedScope = initialScope }
            model.setAccountEnabled("a", enabled: true)
        }
        func clean() { model.stop(); defaults.removePersistentDomain(forName: domain) }
    }

    @MainActor private final class ToolPause {
        private var started = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?
        func wait() async {
            started = true
            startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { waiter = $0 }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func release() { waiter?.resume(); waiter = nil }
    }
}

private actor AssistantProviderFixture: AIProvider {
    enum Reply: Sendable {
        case complete(AIResponse), interrupted(String), streamed([String], AIResponse?), streamedSuspended([String]), suspended
    }
    private var replies: [Reply]
    private(set) var requests: [AIRequest] = []
    private var suspended: AsyncThrowingStream<AIEvent, any Error>.Continuation?
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(replies: [Reply]) { self.replies = replies }
    private var modelsUnavailable = false
    func setModelsUnavailable(_ value: Bool) { modelsUnavailable = value }
    func models() async throws -> [AIModel] {
        if modelsUnavailable { throw AIProviderError.network }
        return [.init(id: "test", displayName: "Test model")]
    }
    nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.start(request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
    func release(_ response: AIResponse) {
        suspended?.yield(.completed(response)); suspended?.finish(); suspended = nil
    }
    private func start(_ request: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
        requests.append(request)
        let ready = requestWaiters.filter { requests.count >= $0.0 }
        requestWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard !replies.isEmpty else { continuation.finish(throwing: AIProviderError.invalidResponse); return }
        switch replies.removeFirst() {
        case .complete(let value): continuation.yield(.completed(value)); continuation.finish()
        case .interrupted(let value): continuation.yield(.textDelta(value)); continuation.finish()
        case .streamed(let fragments, let response):
            for fragment in fragments { continuation.yield(.textDelta(fragment)) }
            if let response { continuation.yield(.completed(response)) }
            continuation.finish()
        case .streamedSuspended(let fragments):
            suspended = continuation
            for fragment in fragments { continuation.yield(.textDelta(fragment)) }
        case .suspended: suspended = continuation
        }
    }
}
