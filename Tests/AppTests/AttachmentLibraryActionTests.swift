import AppKit
import GmailAPI
import MailStore
import QuickLook
import QuickLookUI
import SwiftUI
import SyncEngine
import Testing
@testable import Tern

@MainActor @Suite struct AttachmentLibraryActionTests {
    @Test func busyCommandsCannotReplaceAnOpenWithRetry() async throws {
        let mailbox = try mailbox()
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        var attempts = 0
        let model = AttachmentLibraryModel(mailbox: mailbox, openWithFile: { _ in
            attempts += 1
            if attempts == 1 {
                for await _ in gate.stream { break }
                throw GmailError.unauthorized
            }
        })
        let item = file(account: "audit")
        let opening = Task { await model.openWith(item) }
        defer { opening.cancel() }
        try await waitUntil { attempts == 1 }
        #expect(model.isWorking)
        // Each command would fail for this nonexistent account if it were admitted.
        let unavailable = file(account: "missing")
        await model.preview(unavailable)
        await model.copyFile(unavailable)
        await model.openFile(unavailable)
        await model.retryIndexing()
        await model.retryLastAction()
        #expect(model.isWorking)
        #expect(model.errorMessage == nil)
        gate.continuation.yield()
        await opening.value
        #expect(!model.isWorking)
        #expect(model.errorMessage?.contains("Sign in") == true)
        await model.retryLastAction()
        #expect(attempts == 2)
        #expect(model.errorMessage == nil)
        #expect(model.previewURL == nil)
        await mailbox.stop()
    }

    @Test func previewRetryKeepsTheOriginalSelectionAfterItChanges() async throws {
        let mailbox = try mailbox()
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        let first = file(account: "audit")
        var second = first
        second.partID = "2"
        second.filename = "Second.txt"
        let files = [first.attachment, second.attachment]
        try await mailbox.cache.write { tx in
            let message = MessageRecord(accountID: "audit", id: "m3", threadID: "t2", historyID: 1,
                date: .now, snippet: "", sender: "Example", recipients: "", cc: nil, subject: "Plans", sizeEstimate: 100)
            try tx.replaceLibraryAttachments(files, message: message, labelIDs: [])
        }
        let model = AttachmentLibraryModel(mailbox: mailbox)
        let observing = Task { await model.reload() }
        defer { observing.cancel() }
        try await waitUntil { model.items.count == 2 }
        let focus = try #require(model.items.first)
        model.unavailableAccountIDs = ["audit"]
        model.selection = Set(model.items.map(\.id))
        await model.preview(focus)
        #expect(model.errorMessage != nil)
        model.unavailableAccountIDs = []
        #expect(model.selection.isEmpty)
        await model.retryLastAction()
        #expect(model.previewURLs.count == 2)
        #expect(model.previewURL?.lastPathComponent == focus.filename)
        #expect(model.errorMessage == nil)
        await mailbox.stop()
    }

    @Test func copyReportsPartialFailureAndRetryCopiesTheOriginalSelection() async throws {
        let mailbox = try mailbox()
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        await mailbox.addAccount(AccountRecord(id: "second", email: "second@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now), gmail: AuditGmail())
        let pasteboard = NSPasteboard(name: .init("Tern.AttachmentTests.\(UUID().uuidString)"))
        defer { pasteboard.clearContents() }
        let model = AttachmentLibraryModel(mailbox: mailbox, pasteboard: pasteboard)
        let selected = [file(account: "audit"), file(account: "second")]
        model.unavailableAccountIDs = ["second"]
        await model.copyFiles(selected)
        #expect(urls(in: pasteboard).count == 1)
        #expect(model.errorMessage?.contains("Copied 1 of 2 files") == true)

        model.unavailableAccountIDs = []
        model.selection = []
        await model.retryLastAction()
        let copied = urls(in: pasteboard)
        #expect(copied.count == 2)
        #expect(Set(copied).count == 2)
        #expect(copied.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(model.errorMessage == nil)
        #expect(!model.isWorking)
        await mailbox.stop()
    }

    @Test func selectedPreviewArrivesBeforeSiblingsAndPagingKeepsItsSelection() async throws {
        let transport = LibraryPreviewTransport(blocked: ["file-1", "file-2"], failing: ["file-3"])
        let (mailbox, model, files) = try await previewFixture(transport: transport, count: 4)
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        let focus = try #require(files.last)
        let previewing = Task { await model.preview(focus) }
        defer { previewing.cancel(); Task { await transport.releaseAll() } }
        try await waitUntil { await transport.requests.count == 2 }
        #expect(await transport.requests == ["file-4", "file-1"])
        #expect(model.previewURL?.lastPathComponent == focus.filename)
        #expect(model.previewURLs.map(\.lastPathComponent) == [focus.filename])
        #expect(!model.isWorking)

        await transport.release("file-1")
        try await waitUntil { await transport.requests.count == 3 }
        #expect(model.previewURLs.map(\.lastPathComponent) == [files[0].filename, focus.filename])
        let navigated = try #require(model.previewURLs.first)
        model.previewURL = navigated
        await transport.release("file-2")
        await previewing.value
        #expect(model.previewURLs.map(\.lastPathComponent) == [files[0].filename, files[1].filename, focus.filename])
        #expect(model.previewURL == navigated)
        #expect(model.errorMessage == nil)
        await mailbox.stop()
    }

    @Test(arguments: PreviewDismissal.allCases)
    func dismissedPreviewCannotPublishLateFilesOrOverwriteANewerError(_ dismissal: PreviewDismissal) async throws {
        let blocked = dismissal == .beforeSelected ? "file-2" : "file-1"
        let transport = LibraryPreviewTransport(blocked: [blocked], failing: [blocked])
        let (mailbox, model, files) = try await previewFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        let focus = try #require(files.last)
        let previewing = Task { await model.preview(focus) }
        defer { previewing.cancel(); Task { await transport.releaseAll() } }
        try await waitUntil { await transport.isWaiting(for: blocked) }
        if dismissal != .beforeSelected { #expect(model.previewURL != nil) }
        switch dismissal {
        case .beforeSelected, .binding: model.previewURL = nil
        case .presentation: model.dismissPresentation()
        case .access: model.unavailableAccountIDs = ["audit"]
        }
        #expect(model.previewURL == nil && model.previewURLs.isEmpty)
        #expect(!model.isWorking)
        await model.copyFile(file(account: "missing"))
        let newerError = try #require(model.errorMessage)
        await transport.release(blocked)
        await previewing.value
        #expect(model.previewURL == nil && model.previewURLs.isEmpty)
        #expect(model.errorMessage == newerError)
        #expect(!model.isWorking)
        await mailbox.stop()
    }

    @Test(arguments: [false, true])
    func cancellingPreviewStopsPreparationAndKeepsAnyDisplayedFile(afterPublication: Bool) async throws {
        let blocked = afterPublication ? "file-1" : "file-3"
        let transport = LibraryPreviewTransport(blocked: [blocked])
        let (mailbox, model, files) = try await previewFixture(transport: transport, count: 3)
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        let focus = try #require(files.last)
        let previewing = Task { await model.preview(focus) }
        defer { previewing.cancel(); Task { await transport.releaseAll() } }
        try await waitUntil { await transport.isWaiting(for: blocked) }
        let displayed = model.previewURL
        previewing.cancel()
        await transport.release(blocked)
        await previewing.value
        #expect(await transport.requests == (afterPublication ? ["file-3", "file-1"] : ["file-3"]))
        #expect(model.previewURLs == [displayed].compactMap { $0 })
        #expect(model.previewURL == displayed)
        #expect((displayed != nil) == afterPublication)
        #expect(model.errorMessage == nil && !model.isWorking)
        await model.retryLastAction()
        #expect(model.errorMessage == nil && !model.isWorking)
        await mailbox.stop()
    }

    @Test func replacingTheSelectedOwnerRejectsLateSiblingResults() async throws {
        let transport = LibraryPreviewTransport(blocked: ["file-1"])
        let (mailbox, model, files) = try await previewFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        let account = AccountRecord(id: "second", email: "second@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(account, gmail: AuditGmail())
        var focus = try #require(files.last)
        focus.accountID = "second"
        // Keep the selected owner idle while a different owner's sibling is stalled.
        let message = MessageRecord(accountID: "second", id: "m3", threadID: "t2", historyID: 1,
            date: .now, snippet: "", sender: "Example", recipients: "", cc: nil, subject: "Plans", sizeEstimate: 100)
        let attachment = focus.attachment
        try await mailbox.cache.write { try $0.replaceLibraryAttachments([attachment], message: message, labelIDs: []) }
        let observing = Task { await model.reload() }
        defer { observing.cancel() }
        try await waitUntil { model.items.count == 3 }
        model.selection = Set(model.items.map(\.id))
        let previewing = Task { await model.preview(focus) }
        defer { previewing.cancel(); Task { await transport.releaseAll() } }
        try await waitUntil { await transport.isWaiting(for: "file-1") }
        #expect(model.previewURL != nil)
        await mailbox.replaceAccountRuntime(record: account, gmail: AuditGmail(), syncEnabled: true)
        await transport.release("file-1")
        await previewing.value
        #expect(model.previewURL == nil && model.previewURLs.isEmpty)
        #expect(model.errorMessage == nil && !model.isWorking)
        await mailbox.stop()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--attachment-audit")
                   && ProcessInfo.processInfo.arguments.contains("--ui-audit")
                   && ProcessInfo.processInfo.arguments.contains("--attachment-live")))
    func nativePreviewStartsBeforeSiblingsPreservesNavigationAndStaysClosed() async throws {
        let transport = LibraryPreviewTransport(blocked: ["file-1", "file-2", "file-3"])
        let (mailbox, model, files) = try await previewFixture(transport: transport, count: 4)
        let controller = NSHostingController(rootView: LibraryPreviewHost(model: model))
        controller.sizingOptions = []
        NSApp.activate()
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 500, height: 200))
        window.makeKeyAndOrderFront(nil)
        let focus = try #require(files.last)
        let previewing = Task { await model.preview(focus) }
        var stage = "initial panel"
        defer {
            recordPreviewState("finishing at \(stage)", model: model, window: window)
            let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
            let view = panel?.isVisible == true ? panel?.contentView : controller.view
            if let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    Attachment.record(Array(data), named: "library-preview-final-state.png")
                }
            }
            model.dismissPresentation()
            previewing.cancel()
            Task { await transport.releaseAll() }
            QLPreviewPanel.shared()?.orderOut(nil)
            window.close()
            window.contentViewController = nil
            try? FileManager.default.removeItem(at: mailbox.downloadsDirectory)
        }
        recordPreviewState(stage, model: model, window: window)
        try await waitUntil {
            QLPreviewPanel.sharedPreviewPanelExists()
                && QLPreviewPanel.shared()?.isVisible == true
                && QLPreviewPanel.shared()?.currentPreviewItem?.previewItemURL?.lastPathComponent == focus.filename
        }
        let panel = try #require(QLPreviewPanel.shared())
        recordPreviewState("selected visible", model: model, window: window)
        #expect(await transport.isWaiting(for: "file-1"))
        #expect(panel.dataSource?.numberOfPreviewItems(in: panel) == 1)
        await transport.release("file-1")
        stage = "first sibling appended"
        try await waitUntil { panel.dataSource?.numberOfPreviewItems(in: panel) == 2 }
        recordPreviewState(stage, model: model, window: window)
        #expect(panel.currentPreviewItem?.previewItemURL?.lastPathComponent == focus.filename)
        try sendPreviewKey("\u{F702}", code: 123, to: panel)
        stage = "native left arrow"
        try await waitUntil { panel.currentPreviewItem?.previewItemURL?.lastPathComponent == files[0].filename }
        recordPreviewState(stage, model: model, window: window)
        await transport.release("file-2")
        stage = "second sibling appended"
        try await waitUntil { panel.dataSource?.numberOfPreviewItems(in: panel) == 3 }
        recordPreviewState(stage, model: model, window: window)
        #expect(panel.currentPreviewItem?.previewItemURL?.lastPathComponent == files[0].filename)
        stage = "waiting for actual native close"
        recordPreviewState(stage, model: model, window: window)
        print("TERN_LIBRARY_PREVIEW_READY_TO_CLOSE")
        try await waitUntil(timeout: .seconds(60)) { !panel.isVisible && model.previewURL == nil }
        recordPreviewState(stage, model: model, window: window)
        await transport.release("file-3")
        await previewing.value
        #expect(!panel.isVisible)
        #expect(model.previewURL == nil && model.previewURLs.isEmpty)
        await mailbox.stop()
    }

    private func previewFixture(transport: LibraryPreviewTransport, count: Int = 2) async throws
        -> (MailboxModel, AttachmentLibraryModel, [AttachmentLibraryItem]) {
        let gmail = GmailClient(tokens: LibraryPreviewTokens(), transport: transport, retryDelays: [])
        let mailbox = try mailbox(gmail: gmail)
        let attachments = (1...count).map { index in
            AttachmentRecord(accountID: "audit", messageID: "m3", partID: String(index), attachmentID: "file-\(index)",
                filename: "\(index).txt", mimeType: "text/plain", size: LibraryPreviewTransport.bytes.count, isInline: false)
        }
        try await mailbox.cache.write { tx in
            let message = MessageRecord(accountID: "audit", id: "m3", threadID: "t2", historyID: 1,
                date: .now, snippet: "", sender: "Example", recipients: "", cc: nil, subject: "Plans", sizeEstimate: 100)
            try tx.replaceLibraryAttachments(attachments, message: message, labelIDs: [])
        }
        let model = AttachmentLibraryModel(mailbox: mailbox)
        model.sort = .filename
        let observing = Task { await model.reload() }
        defer { observing.cancel() }
        try await waitUntil { model.items.count == count }
        model.selection = Set(model.items.map(\.id))
        return (mailbox, model, model.items)
    }

    private func mailbox(gmail: any GmailService = AuditGmail()) throws -> MailboxModel {
        MailboxModel(account: AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now), cache: try MailCache.inMemory(), gmail: gmail,
            outgoingDirectory: FileManager.default.temporaryDirectory,
            downloadsDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    private func file(account: String) -> AttachmentLibraryItem {
        let attachment = AttachmentRecord(accountID: account, messageID: "m3", partID: "1", attachmentID: "a-m3",
            filename: "Trail map.txt", mimeType: "text/plain",
            size: Data("Synthetic attachment for the UI audit.\n".utf8).count, isInline: false)
        return AttachmentLibraryItem(attachment: attachment, threadID: "t2", sender: "Example", subject: "Plans", date: .now)
    }

    private func urls(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }

    private func waitUntil(timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition(), sourceLocation: sourceLocation)
    }

    private func recordPreviewState(_ stage: String, model: AttachmentLibraryModel, window: NSWindow) {
        let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
        let current = panel?.currentPreviewItem?.previewItemURL?.lastPathComponent ?? "none"
        let bound = model.previewURL?.lastPathComponent ?? "none"
        let count = panel.flatMap { $0.dataSource?.numberOfPreviewItems(in: $0) } ?? 0
        let closeButton = panel?.standardWindowButton(.closeButton)
        let closeAction = (closeButton?.action).map(NSStringFromSelector) ?? "none"
        let closeTarget = (closeButton?.target).map { String(describing: type(of: $0)) } ?? "none"
        let currentController = (panel?.currentController).map { String(describing: type(of: $0)) } ?? "none"
        print("TERN_LIBRARY_PREVIEW stage=\(stage) bound=\(bound) prepared=\(model.previewURLs.map(\.lastPathComponent)) appActive=\(NSApp.isActive) panelVisible=\(panel?.isVisible == true) panelKey=\(panel?.isKeyWindow == true) nativeURL=\(current) nativeCount=\(count) nativeIndex=\(panel?.currentPreviewItemIndex ?? -1) controller=\(currentController) closeHidden=\(closeButton?.isHidden == true) closeEnabled=\(closeButton?.isEnabled == true) closeTarget=\(closeTarget) closeAction=\(closeAction) hostVisible=\(window.isVisible) hostKey=\(window.isKeyWindow)")
    }

    private func sendPreviewKey(_ characters: String, code: UInt16, to panel: QLPreviewPanel) throws {
        panel.makeKeyAndOrderFront(nil)
        let modifiers: NSEvent.ModifierFlags = code == 123 ? [.function, .numericPad] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            panel.sendEvent(event)
        }
    }

    enum PreviewDismissal: CaseIterable, Sendable { case beforeSelected, binding, presentation, access }
}

private struct LibraryPreviewHost: View {
    @Bindable var model: AttachmentLibraryModel
    var body: some View {
        Text("Attachment preview")
            .quickLookPreview($model.previewURL, in: model.previewURLs)
    }
}

private struct LibraryPreviewTokens: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "synthetic-preview-token" }
}

private actor LibraryPreviewTransport: HTTPTransport {
    static let bytes = Data("Synthetic preview file.\n".utf8)
    private let blocked: Set<String>
    private let failing: Set<String>
    private var released: Set<String> = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var requests: [String] = []

    init(blocked: Set<String>, failing: Set<String> = []) {
        self.blocked = blocked
        self.failing = failing
    }

    func isWaiting(for id: String) -> Bool { pending[id] != nil }
    func release(_ id: String) {
        released.insert(id)
        pending.removeValue(forKey: id)?.resume()
    }
    func releaseAll() { for id in Array(pending.keys) { release(id) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let id = url.lastPathComponent
        requests.append(id)
        // Deliberately finish even after cancellation to exercise late-result rejection.
        if blocked.contains(id), !released.contains(id) { await withCheckedContinuation { pending[id] = $0 } }
        if failing.contains(id) { throw GmailError.unauthorized }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let body = try JSONSerialization.data(withJSONObject: ["data": Self.bytes.base64EncodedString()])
        return (body, response)
    }
}
