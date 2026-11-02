import AppKit
import Foundation
import GmailAPI
import MailStore
import MessageContent
import SwiftUI
import SyncEngine
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct ComposeAssistantTests {
    @Test func replyContextStaysWithTheComposerAndFollowupsIncludeUnappliedSuggestions() async throws {
        let search = try Self.call("search_mail", ["query": .string("plans"), "account_id": .string("audit"), "page_token": .null])
        let check = try Self.call("check_requested_availability", ["calendars": .null,
            "start": .string("2030-01-11T19:00:00+01:00"), "end": .string("2030-01-11T21:00:00+01:00"),
            "time_zone": .string("Europe/Vienna")])
        let provider = Provider(replies: [.complete(Self.response(search)), .complete(Self.response(check)),
            .complete(try Self.suggestion("Dinner on Friday?")), .complete(Self.answer("Friday at 19:00 is available.")),
            .complete(try Self.suggestion("How about dinner next Friday?")), .complete(Self.answer("Updated."))])
        let fixture = try await Fixture(provider: provider)
        defer { fixture.stop() }
        fixture.compose.content.body = ComposeDocument(plainText: "Unsaved notes for this reply")
        fixture.compose.content.to = [.init(name: "River", address: "river@example.invalid")]
        // A different reader selection must not change the composer target.
        fixture.access.selectedThreads = [.init(accountID: "other", threadID: "other-thread")]
        fixture.access.currentAccounts = ["other"]
        fixture.assistant.selectedScope = .selectedThreads
        fixture.model.prompt = "Write a reply inviting her to dinner next Friday."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()

        #expect(fixture.model.proposal?.body == "Dinner on Friday?")
        #expect(fixture.compose.content.body.plainText() == "Unsaved notes for this reply")
        #expect(fixture.reads.calendarChecks == 1)
        #expect(fixture.reads.calls.map(\.name) == ["read_thread", "search_mail", "check_requested_availability"])
        #expect(fixture.reads.scopes.allSatisfy { $0.accountIDs == ["audit"] && $0.threadIDs == nil })
        let requests = await provider.requests
        let first = try Self.userContext(try #require(requests.first))
        #expect(first["compose_context"]?["thread_id"] == .string("t2"))
        #expect(first["compose_context"]?["source_message_id"] == .string("m3"))
        #expect(first["compose_context"]?["body"] == .string("Unsaved notes for this reply"))
        #expect(first["compose_context"]?["to"]?.arrayValue?.first?["address"] == .string("river@example.invalid"))
        #expect(first["current_thread"]?["messages"]?.arrayValue?.count == 2)
        #expect(try first.jsonString().contains("The latest reply."))
        #expect(requests.allSatisfy { $0.tools.allSatisfy {
            ComposeAssistantSession.readToolNames.contains($0.name) || $0.name == "propose_composer_draft"
        } })

        fixture.compose.content.body = ComposeDocument(plainText: "My new edit while considering the suggestion")
        fixture.model.prompt = "Make your suggestion warmer, keeping my new edit in mind."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        let followup = try Self.userContext(try #require(await provider.requests.last))
        #expect(followup["compose_context"]?["body"] == .string("My new edit while considering the suggestion"))
        #expect(try followup.jsonString().contains("Dinner on Friday?"))
        #expect(fixture.model.proposal?.body == "How about dinner next Friday?")
        #expect(fixture.model.canApply)
        #expect(fixture.compose.draft?.state == .editing)
        await fixture.close()
    }

    @Test func applyingAndUndoingPreserveProtectedDraftContentAndRefuseInterveningEdits() async throws {
        let provider = Provider(replies: [.complete(try Self.suggestion("Would you like dinner on Friday?")),
            .complete(Self.answer("Ready.")), .complete(try Self.suggestion("Dinner this Friday?")),
            .complete(Self.answer("Ready."))])
        let fixture = try await Fixture(provider: provider, attachment: true)
        defer { fixture.stop() }
        let image = InlineImageReference(contentID: "image@example.invalid", altText: "Map")
        fixture.compose.content.body = ComposeDocument(blocks: [
            .init(runs: [.init("Original formatted message", bold: true), .init("", image: image)])
        ])
        fixture.compose.content.signatureHTML = "<p>My signature</p>"
        fixture.compose.content.cc = [.init(address: "cc@example.invalid")]
        fixture.compose.content.bcc = [.init(address: "bcc@example.invalid")]
        let original = fixture.compose.content
        let attachments = fixture.compose.attachments
        let quote = fixture.compose.draft?.quotedPlainText
        fixture.model.prompt = "Write an invitation."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.canApply)

        fixture.compose.content.subject = "Edited after the request"
        fixture.model.apply()
        #expect(fixture.compose.content.subject == "Edited after the request")
        #expect(fixture.compose.content.body == original.body)
        #expect(fixture.model.errorMessage != nil)
        fixture.compose.content = original
        fixture.model.apply()
        #expect(fixture.compose.content.body.plainText().hasPrefix("Would you like dinner on Friday?"))
        #expect(fixture.compose.content.body.blocks.flatMap(\.runs).compactMap(\.image) == [image])
        #expect(fixture.compose.content.to == original.to && fixture.compose.content.cc == original.cc)
        #expect(fixture.compose.content.bcc == original.bcc && fixture.compose.content.fromAddress == original.fromAddress)
        #expect(fixture.compose.content.signatureHTML == original.signatureHTML)
        #expect(fixture.compose.attachments == attachments)
        #expect(fixture.compose.draft?.quotedPlainText == quote)
        #expect(fixture.compose.draft?.inReplyTo == "<original@example.invalid>")
        #expect(fixture.model.canUndo)
        fixture.model.undo()
        #expect(fixture.compose.content == original)

        fixture.model.prompt = "Try again."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        fixture.model.apply()
        fixture.compose.content.body = ComposeDocument(plainText: "Keep this later edit")
        #expect(!fixture.model.canUndo)
        fixture.model.undo()
        #expect(fixture.compose.content.body.plainText() == "Keep this later edit")
        #expect(fixture.compose.draft?.state == .editing)
        await fixture.close()
    }

    @Test func mutationsAreRejectedBeforeDispatchAndUnavailableAccountsCannotStart() async throws {
        let provider = Provider(replies: [.complete(Self.response(try Self.call("prepare_draft", [:])))])
        let fixture = try await Fixture(provider: provider)
        defer { fixture.stop() }
        let session = try fixture.assistant.makeComposeSession(accountID: "audit")
        for name in ["prepare_draft", "prepare_calendar_event", "prepare_calendar_deletion", "send_email"] {
            await #expect(throws: AssistantError.self) {
                try await session.tools.execute(Self.call(name, [:]))
            }
        }
        #expect(fixture.reads.calls.isEmpty)
        fixture.model.prompt = "Draft a reply."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.last?.state == .failed)
        #expect(fixture.model.proposal == nil)
        #expect(fixture.reads.calls.map(\.name) == ["read_thread"])
        #expect(fixture.compose.draft?.state == .editing)

        fixture.assistant.setAccountEnabled("audit", enabled: false)
        fixture.model.refreshAccess()
        fixture.model.prompt = "Try without permission."
        fixture.model.send()
        #expect(fixture.model.availabilityMessage != nil)
        #expect(!fixture.model.isRunning)
        #expect(await provider.requests.count == 1)
        fixture.assistant.setAccountEnabled("audit", enabled: true)
        fixture.access.canUsePlan = false
        fixture.model.prompt = "Try without a connection."
        fixture.model.send()
        #expect(fixture.model.availabilityMessage != nil)
        #expect(await provider.requests.count == 1)
        await fixture.close()
    }

    @Test(arguments: ["mail", "calendar", "connection", "account-instance", "model", "mail-restored", "model-restored"])
    func accessChangesClearIdleContentAndDiscardLateResponses(change: String) async throws {
        for duringResponse in [false, true] {
            let replies: [Provider.Reply] = duringResponse ? [.suspended] : [
                .complete(try Self.suggestion("Private preview")), .complete(Self.answer("Private answer"))]
            let provider = Provider(replies: replies)
            let fixture = try await Fixture(provider: provider)
            defer { fixture.stop() }
            fixture.model.prompt = "Private request"
            fixture.model.send()
            if duringResponse { try await Self.waitUntil { await provider.requests.count == 1 } }
            else {
                await fixture.model.waitForCurrentTurn()
                #expect(fixture.model.proposal != nil)
            }
            fixture.model.prompt = "Private unfinished prompt"
            switch change {
            case "mail": fixture.assistant.setAccountEnabled("audit", enabled: false)
            case "calendar": fixture.access.calendarScope = .init(revision: 2)
            case "connection": fixture.access.connectionRevision += 1
            case "account-instance": fixture.access.instance = "replacement-instance"
            case "model": fixture.assistant.selectedModelID = "other-model"
            case "mail-restored":
                fixture.assistant.setAccountEnabled("audit", enabled: false)
                fixture.assistant.setAccountEnabled("audit", enabled: true)
            case "model-restored":
                let modelID = fixture.assistant.selectedModelID
                fixture.assistant.selectedModelID = "other-model"
                fixture.assistant.selectedModelID = modelID
            default: Issue.record("Unknown access-change fixture")
            }
            fixture.model.refreshAccess()
            #expect(fixture.model.messages.isEmpty)
            #expect(fixture.model.prompt.isEmpty)
            #expect(fixture.model.proposal == nil)
            #expect(!fixture.model.isRunning && !fixture.model.canApply)
            if duringResponse {
                await provider.release(try Self.suggestion("Late private result"))
                await Task.yield()
                #expect(fixture.model.messages.isEmpty && fixture.model.proposal == nil)
            }
            await fixture.close()
        }
    }

    @Test func stoppingAfterPreviewKeepsTheSuggestionAvailableForRefinement() async throws {
        let provider = Provider(replies: [.complete(try Self.suggestion("First invitation")), .suspended,
            .complete(try Self.suggestion("Shorter invitation")), .complete(Self.answer("Updated."))])
        let fixture = try await Fixture(provider: provider)
        defer { fixture.stop() }
        fixture.model.prompt = "Write the invitation."
        fixture.model.send()
        try await Self.waitUntil { await provider.requests.count == 2 }
        #expect(fixture.model.proposal?.body == "First invitation")
        fixture.model.stop()
        await provider.release(Self.answer("Late text"))
        fixture.model.prompt = "Make that invitation shorter."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.proposal?.body == "Shorter invitation")
        let context = try Self.userContext(try #require(await provider.requests.last))
        #expect(try context.jsonString().contains("First invitation"))
        #expect(fixture.compose.content.body.plainText() == "Original draft")
        await fixture.close()
    }

    @Test func compactPanelRendersAndPresentsGeneratedPreview() async throws {
        let provider = Provider(replies: [.complete(try Self.suggestion("Hi River,\n\nWould you like to have dinner next Friday at 19:00?\n\nSee you soon!")),
            .complete(Self.answer("I used Friday, 11 January, at 19:00 in Europe/Vienna, assuming two hours."))])
        let fixture = try await Fixture(provider: provider)
        defer { fixture.stop() }
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let host = NSHostingView(rootView: ComposeAssistantView(model: fixture.model, assistant: fixture.assistant, onClose: {}))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 456, height: 112),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 456)
        #expect(host.fittingSize.height <= 160)
        fixture.model.prompt = "Invite her to dinner next Friday."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        #expect(fixture.model.proposal != nil)
        try Self.capture(host, name: "tern-compose-assistant-panel.png")
        if let popover = NSApp.windows.first(where: {
            $0 !== window && $0.isVisible && !originalWindows.contains(ObjectIdentifier($0))
        }), let content = popover.contentView {
            content.layoutSubtreeIfNeeded()
            try Self.capture(content, name: "tern-compose-assistant-preview.png")
            popover.orderOut(nil)
        } else { Issue.record("The generated proposal did not open its review popover") }
        await fixture.close()
    }

    @Test func contextFilesRequireAnExplicitAskPreserveFollowupsAndDisappearFromHistoryWhenRemoved() async throws {
        let provider = Provider(replies: [.complete(try Self.suggestion("Original suggestion")), .complete(Self.answer("Ready.")),
            .complete(Self.answer("Used the reference.")), .complete(Self.answer("Kept the reference.")), .complete(Self.answer("New chat."))])
        let fixture = try await Fixture(provider: provider, attachment: true)
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Self.file(in: directory, name: "reference.txt", data: Data("private-context-marker".utf8))
        fixture.model.prompt = "Suggest a reply."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        let original = fixture.compose.content
        let outgoing = fixture.compose.attachments
        let file = ComposeDroppedFile(url: url)
        fixture.model.addContextFiles([file])
        await fixture.model.waitForContextImports()
        #expect(!fixture.model.hasContextFileErrors)
        #expect(fixture.model.messages.count == 2)
        #expect(await provider.requests.count == 2)
        #expect(fixture.compose.content == original && fixture.compose.attachments == outgoing)

        fixture.model.prompt = "Use this reference to revise that."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        let first = try Self.userContext(try #require(await provider.requests.last))
        #expect(first["previous_suggestion"]?["body"] == .string("Original suggestion"))
        #expect(first["ai_context_files"]?.arrayValue?.first?["text"] == .string("private-context-marker"))
        #expect(!((try first.jsonString()).contains(directory.path)))
        fixture.model.prompt = "Keep it shorter."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        let followup = try #require(await provider.requests.last)
        #expect(try AIJSON.array(followup.input).jsonString().components(separatedBy: "private-context-marker").count == 2)
        #expect(try Self.userContext(followup)["ai_context_files"]?.arrayValue?.first?["contents_in_earlier_turn"] == .bool(true))
        fixture.model.removeContextFile(file.id)
        #expect(fixture.model.messages.isEmpty && fixture.model.contextAttachments.isEmpty)
        #expect(fixture.model.statusText == "File removed. Started a new chat.")
        fixture.model.prompt = "Write without the reference."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        #expect(try !AIJSON.array(try #require(await provider.requests.last).input).jsonString().contains("private-context-marker"))
        #expect(fixture.compose.content == original && fixture.compose.attachments == outgoing)
        await fixture.close()
    }

    @Test func imageContextUsesBoundedImageInputInsteadOfSendingItAsAnEmailAttachment() async throws {
        let provider = Provider(replies: [.complete(Self.answer("The image is available."))])
        let fixture = try await Fixture(provider: provider)
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 160, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let url = try Self.file(in: directory, name: "reference.png", data: #require(bitmap.representation(using: .png, properties: [:])))
        fixture.model.addContextFiles([ComposeDroppedFile(url: url)])
        await fixture.model.waitForContextImports()
        #expect(!fixture.model.hasContextFileErrors)
        #expect(await provider.requests.isEmpty)
        fixture.model.prompt = "Use this image as reference."
        fixture.model.send()
        await fixture.model.waitForCurrentTurn()
        let request = try #require(await provider.requests.last)
        let parts = try #require(request.input.last?["content"]?.arrayValue)
        let image = try #require(parts.first { $0["type"] == .string("input_image") })
        let dataURL = try #require(image["image_url"]?.stringValue)
        #expect(dataURL.hasPrefix("data:image/jpeg;base64,"))
        #expect(dataURL.utf8.count <= ComposeAssistantFileReader.maximumJPEGBytes * 4 / 3 + 40)
        #expect(try AIJSON.array(request.input).encoded().count <= AssistantModel.maximumHistoryBytes)
        #expect(try Self.userContext(request)["ai_context_files"]?.arrayValue?.first?["truncated"] == .bool(true))
        #expect(fixture.compose.attachments.isEmpty && fixture.compose.content.body.plainText() == "Original draft")
        await fixture.close()
    }

    @Test func contextFileLimitsBlockRequestsUntilFailuresAreRemovedOrRetried() async throws {
        let provider = Provider(replies: [])
        let fixture = try await Fixture(provider: provider)
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unicode = try Self.file(in: directory, name: "notes.txt", data: Data(String(repeating: "€", count: 10_000).utf8))
        let excerpt = try ComposeAssistantFileReader.read(url: unicode, id: UUID(), filename: "notes.txt")
        #expect(excerpt.truncated && excerpt.text?.utf8.count == 12_000)
        #expect(excerpt.text?.contains("�") == false)
        let oversized = try Self.file(in: directory, name: "large.txt", data: Data(repeating: 65, count: AssistantMailLimits.attachmentBytes + 1))
        #expect(throws: AssistantMailError.self) { try ComposeAssistantFileReader.read(url: oversized, id: UUID(), filename: "large.txt") }
        let unsupported = try Self.file(in: directory, name: "notes.docx", data: Data("unsupported".utf8))
        #expect(throws: AttachmentTextReader.ReadError.self) { try ComposeAssistantFileReader.read(url: unsupported, id: UUID(), filename: "notes.docx") }

        let text = try Self.file(in: directory, name: "quotes.txt", data: Data(String(repeating: "\"", count: 12_000).utf8))
        fixture.model.addContextFiles((0..<5).map { _ in ComposeDroppedFile(url: text) })
        #expect(fixture.model.contextAttachments.count == 4)
        await fixture.model.waitForContextImports()
        #expect(fixture.model.hasContextFileErrors && !fixture.model.canAsk)
        fixture.model.prompt = "Use all files."
        fixture.model.send()
        #expect(await provider.requests.isEmpty)
        let failed = try #require(fixture.model.contextAttachments.first { $0.errorMessage != nil })
        for item in fixture.model.contextAttachments where item.id != failed.id { fixture.model.removeContextFile(item.id) }
        fixture.model.retryContextFile(failed.id)
        await fixture.model.waitForContextImports()
        #expect(!fixture.model.hasContextFileErrors && fixture.model.contextAttachments.first?.state == .ready)
        #expect(fixture.compose.attachments.isEmpty && fixture.compose.content.body.plainText() == "Original draft")
        await fixture.close()
    }

    @Test(arguments: ["clear", "remove", "revoke"])
    func pendingContextImportsCannotPublishAfterRemovalOrAccessChanges(action: String) async throws {
        let provider = Provider(replies: [])
        let fixture = try await Fixture(provider: provider)
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Self.file(in: directory, name: "private.txt", data: Data("late-private-context".utf8))
        let gate = FileGate()
        let file = ComposeDroppedFile(filename: "private.txt", load: { try await gate.load() })
        fixture.model.addContextFiles([file])
        try await Self.waitUntil { gate.isWaiting }
        fixture.model.prompt = "Use the pending file."
        fixture.model.send()
        #expect(!fixture.model.isRunning)
        #expect(await provider.requests.isEmpty)
        var isWaitingForImports = false
        let completion = Task { isWaitingForImports = true; await fixture.model.waitForContextImports() }
        try await Self.waitUntil { isWaitingForImports }
        switch action {
        case "clear": fixture.model.clear()
        case "remove": fixture.model.removeContextFile(file.id)
        default:
            fixture.assistant.setAccountEnabled("audit", enabled: false)
            fixture.model.refreshAccess()
        }
        gate.release(url)
        await completion.value
        #expect(fixture.model.contextAttachments.isEmpty && fixture.model.messages.isEmpty)
        #expect(fixture.compose.attachments.isEmpty && fixture.compose.content.body.plainText() == "Original draft")
        #expect(await provider.requests.isEmpty)
        await fixture.close()
    }

    private static func file(in directory: URL, name: String, data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    @MainActor private final class FileGate {
        private var continuation: CheckedContinuation<URL, any Error>?
        var isWaiting: Bool { continuation != nil }
        func load() async throws -> URL {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func release(_ url: URL) { continuation?.resume(returning: url); continuation = nil }
    }

    private static func capture(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try data.write(to: url)
        print("Compose assistant rendering: \(url.path)")
    }

    private static func userContext(_ request: AIRequest) throws -> AIJSON {
        let content = try #require(request.input.last(where: { $0["role"] == .string("user") })?["content"])
        let text = try #require(content.stringValue ?? content.arrayValue?.first?["text"]?.stringValue)
        return try AIJSON.decode(Data(text.utf8))
    }
    private static func call(_ name: String, _ args: [String: AIJSON]) throws -> AIToolCall {
        .init(id: UUID().uuidString, namespace: "tern", name: name, arguments: try AIJSON.object(args).jsonString())
    }
    private static func suggestion(_ body: String) throws -> AIResponse {
        response(try call("propose_composer_draft", ["subject": .string("Re: Weekend plans"), "body": .string(body)]))
    }
    private static func response(_ call: AIToolCall) -> AIResponse {
        .init(output: [.object(["type": .string("function_call"), "call_id": .string(call.id),
            "namespace": .string(call.namespace), "name": .string(call.name), "arguments": .string(call.arguments)])],
            text: "", toolCalls: [call])
    }
    private static func answer(_ text: String) -> AIResponse {
        .init(output: [.object(["type": .string("message"), "role": .string("assistant"), "content": .array([
            .object(["type": .string("output_text"), "text": .string(text)])
        ])])], text: text, toolCalls: [])
    }
    private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition(), "The compose assistant did not reach the expected state")
    }

    @MainActor private final class Access {
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: "Audit", grantedScopes: [], addedAt: .distantPast)
        var selectedThreads: Set<ThreadKey> = []
        var currentAccounts: Set<String> = ["audit"]
        var instance = "original-instance"
        var connectionRevision = 1
        var canUsePlan = true
        var calendarScope = AssistantCalendarScope(access: [.init(accountID: "audit", calendarID: "personal"): .availability], revision: 1)
        func value() -> AssistantContext {
            .init(accounts: [account], isAccountListReady: true, currentAccountIDs: currentAccounts,
                selectedThreads: selectedThreads, accountInstances: [account.id: instance],
                connectionRevision: connectionRevision, canUsePlan: canUsePlan, calendarScope: calendarScope)
        }
    }

    @MainActor private final class Reads {
        var calls: [AIToolCall] = []
        var scopes: [AssistantScopeSnapshot] = []
        var calendarChecks = 0
        func tools(mailbox: MailboxModel, snapshot: AssistantScopeSnapshot) -> AssistantToolSession {
            scopes.append(snapshot)
            let mail = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: snapshot.accountIDs) { true }
            let calendar = CalendarAssistantTools(scope: snapshot.calendarScope, bindings: .init(
                calendars: { [.init(key: .init(accountID: "audit", calendarID: "personal"), title: "Personal",
                    canWrite: true, includeInScheduling: true, timeZoneIdentifier: "Europe/Vienna")] },
                read: { _, _ in throw CalendarAssistantTools.ToolError.detailsNotAllowed },
                query: { _, _, _ in throw CalendarAssistantTools.ToolError.detailsNotAllowed },
                availability: { [weak self] _, ids, _, _, hours in
                    self?.calendarChecks += 1
                    return CalendarAvailabilityResult(calendarIDs: ids, timeZone: hours.timeZoneIdentifier, busy: [], slots: [])
                },
                prepare: { _, _, _ in throw AssistantError.invalidTool },
                workingHours: { .init(timeZoneIdentifier: "Europe/Vienna") }
            )) { true }
            return .init(definitions: MailAssistantTools.definitions + CalendarAssistantTools.definitions, execute: { [weak self] call in
                self?.calls.append(call)
                if ComposeAssistantSession.calendarToolNames.contains(call.name) { return try await calendar.execute(call) }
                return try await mail.execute(call)
            })
        }
    }

    @MainActor private final class Fixture {
        let mailbox: MailboxModel
        let compose: ComposeModel
        let assistant: AssistantModel
        let model: ComposeAssistantModel
        let access: Access
        let reads: Reads
        private let directory: URL

        init(provider: any AIProvider, attachment: Bool = false) async throws {
            let access = Access()
            self.access = access
            let reads = Reads()
            self.reads = reads
            let cache = try MailCache.inMemory()
            let directory = FileManager.default.temporaryDirectory.appending(path: "ComposeAssistantTests-\(UUID().uuidString)")
            self.directory = directory
            let mailbox = MailboxModel(account: access.account, cache: cache, gmail: AuditGmail(), outgoingDirectory: directory, syncEnabled: false)
            self.mailbox = mailbox
            let draft = LocalDraft(id: UUID().uuidString, accountID: "audit", kind: .reply,
                content: .init(to: [.init(name: "River", address: "river@example.invalid")], subject: "Re: Weekend plans",
                    body: ComposeDocument(plainText: "Original draft"), fromAddress: "audit@example.invalid"),
                rfcMessageID: "<draft@example.invalid>", threadID: "t2", sourceMessageID: "m3",
                inReplyTo: "<original@example.invalid>", quotedHTML: "<blockquote>Original quote</blockquote>",
                quotedPlainText: "Original quote", now: .now)
            try await cache.write { tx in
                try tx.insertLocalDraft(draft)
                if attachment {
                    _ = try tx.addOutgoingAttachment(.init(localDraftID: draft.id, filename: "map.png", mimeType: "image/png",
                        size: 1, path: "map.png", contentID: "image@example.invalid"), now: .now)
                }
            }
            let compose = ComposeModel(localDraftID: draft.id, mailbox: mailbox)
            self.compose = compose
            let assistant = AssistantModel(app: AppModel(), connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
                provider: provider, context: { access.value() }, makeTools: { reads.tools(mailbox: mailbox, snapshot: $0) })
            self.assistant = assistant
            model = ComposeAssistantModel(compose: compose, assistant: assistant)
            assistant.setAccountEnabled("audit", enabled: true)
            compose.start()
            try await ComposeAssistantTests.waitUntil { self.compose.phase == .open }
            await assistant.refreshConnection()
        }
        func stop() { model.clear(); assistant.stop(); compose.windowClosed() }
        func close() async {
            model.clear()
            await compose.requestClose()
            await mailbox.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private actor Provider: AIProvider {
        enum Reply: Sendable { case complete(AIResponse), suspended }
        private var replies: [Reply]
        private(set) var requests: [AIRequest] = []
        private var suspended: AsyncThrowingStream<AIEvent, any Error>.Continuation?
        init(replies: [Reply]) { self.replies = replies }
        func models() async throws -> [AIModel] {
            [.init(id: "test-model", displayName: "Test"), .init(id: "other-model", displayName: "Other")]
        }
        nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task { await self.start(request, continuation: continuation) }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func release(_ response: AIResponse) {
            suspended?.yield(.completed(response)); suspended?.finish(); suspended = nil
        }
        private func start(_ request: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
            requests.append(request)
            guard !replies.isEmpty else { continuation.finish(throwing: AIProviderError.invalidResponse); return }
            switch replies.removeFirst() {
            case .complete(let response): continuation.yield(.completed(response)); continuation.finish()
            case .suspended: suspended = continuation
            }
        }
    }
}
