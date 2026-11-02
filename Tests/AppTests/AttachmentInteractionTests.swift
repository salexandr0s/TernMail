import AppKit
import MailStore
import QuickLookUI
import SwiftUI
import Testing
@testable import Tern

/// Opt-in native checks using synthetic accounts and files owned by this test.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.arguments.contains("--attachment-audit")))
@MainActor struct AttachmentInteractionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--attachment-live")))
    func quickLookPagesClosesReopensAndTracksRemoval() async throws {
        try requireSyntheticAudit()
        try await withPreviewCleanup {
            let app = AppModel()
            await app.start()
            let mailbox = try #require(app.mailbox)
            let host = try await composeHost(app: app, mailbox: mailbox)
            defer { host.close() }
            let agendaBytes = Data("Agenda for the attachment audit.".utf8)
            let notesBytes = Data("Notes for the attachment audit.".utf8)
            host.model.attach([
                .data(agendaBytes, filename: "agenda.txt", mimeType: "text/plain"),
                .data(notesBytes, filename: "notes.txt", mimeType: "text/plain")
            ])
            try await until { host.model.attachments.count == 2 && host.model.progressText == nil }
            try await press("Open agenda.txt", in: host.root)
            try await until { visiblePreview()?.currentPreviewItem?.previewItemURL?.lastPathComponent == "agenda.txt" }
            let panel = try #require(visiblePreview())
            #expect(panel.dataSource?.numberOfPreviewItems(in: panel) == 2)
            let selectedURL = try #require(panel.currentPreviewItem?.previewItemURL)
            #expect(try Data(contentsOf: selectedURL) == agendaBytes)
            try await capture(try #require(panel.contentView), name: "quick-look-agenda")

            try sendKey("\u{F703}", code: 124, to: panel)
            try await until { panel.currentPreviewItem?.previewItemURL?.lastPathComponent == "notes.txt" }
            let nextURL = try #require(panel.currentPreviewItem?.previewItemURL)
            #expect(try Data(contentsOf: nextURL) == notesBytes)
            try await capture(try #require(panel.contentView), name: "quick-look-next-notes")
            try sendKey("\u{F702}", code: 123, to: panel)
            try await until { panel.currentPreviewItem?.previewItemURL?.lastPathComponent == "agenda.txt" }
            try await closePreview()
            try await until { visiblePreview() == nil }
            #expect(host.window.isVisible, "Closing Quick Look must leave the compose window open")

            print("TERN_ATTACHMENT_AUDIT waiting-for-native-space agenda.txt")
            let spaceDeadline = ContinuousClock.now + .seconds(120)
            while visiblePreview()?.currentPreviewItem?.previewItemURL?.lastPathComponent != "agenda.txt",
                  ContinuousClock.now < spaceDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(visiblePreview()?.currentPreviewItem?.previewItemURL?.lastPathComponent == "agenda.txt",
                         "Press Space on the focused attachment in the native compose window")
            print("TERN_ATTACHMENT_AUDIT native-space-observed")
            try await press("Remove agenda.txt", in: host.root)
            try await until { host.model.attachments.count == 1 && visiblePreview() == nil }
            try await Task.sleep(for: .milliseconds(300))
            #expect(visiblePreview() == nil, "Removing the previewed attachment must not reopen its old preview")
            try await press("Open notes.txt", in: host.root)
            try await until { visiblePreview()?.currentPreviewItem?.previewItemURL?.lastPathComponent == "notes.txt" }
            let remaining = try #require(visiblePreview())
            #expect(remaining.dataSource?.numberOfPreviewItems(in: remaining) == 1)
            try await capture(try #require(remaining.contentView), name: "quick-look-remaining-notes")
            try await closePreview()
            try await until { visiblePreview() == nil }
            #expect(host.window.isVisible, "Closing the remaining preview must leave the compose window open")
            print("TERN_ATTACHMENT_AUDIT quick-look-navigation-and-removal-passed")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--attachment-live")))
    func attachmentFailureCardsRetryRemoveAndKeep() async throws {
        try requireSyntheticAudit()
        try await withPreviewCleanup {
            let app = AppModel()
            await app.start()
            let file = CacheFile()
            let cache = try MailCache.open(at: file.url)
            let directory = FileManager.default.temporaryDirectory.appending(path: "AttachmentAudit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let account = AccountRecord(id: "attachment-audit", email: "attachment@example.invalid", displayName: nil,
                                        grantedScopes: [], addedAt: .now)
            let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
                                       outgoingDirectory: directory.appending(path: "Outgoing"))
            await mailbox.start()
            let host = try await composeHost(app: app, mailbox: mailbox)
            var refusesRemoval = false
            defer {
                if refusesRemoval { try? file.allow("DELETE", on: "outgoingAttachment") }
                host.close()
                try? FileManager.default.removeItem(at: directory)
            }

            let restored = directory.appending(path: "retry.txt")
            host.model.attach([.file(restored)])
            try await until { host.model.failedAttachments.count == 1 && host.model.progressText == nil }
            try await capture(host.root, name: "attachment-missing-file")
            try Data("The source now exists.".utf8).write(to: restored)
            try await press("Retry", in: host.root)
            try await until { host.model.failedAttachments.isEmpty && host.model.attachments.count == 1 }
            #expect(host.model.attachments.first?.filename == "retry.txt")
            try await capture(host.root, name: "attachment-native-retry-succeeded")

            host.model.attach([.file(directory.appending(path: "still-missing.txt"))])
            try await until { host.model.failedAttachments.count == 1 && host.model.progressText == nil }
            try await press("Remove", in: host.root)
            try await until { host.model.failedAttachments.isEmpty }
            #expect(host.model.attachments.count == 1)

            try await press("Open retry.txt", in: host.root)
            try await until { visiblePreview()?.currentPreviewItem?.previewItemURL?.lastPathComponent == "retry.txt" }
            let previewURL = try #require(visiblePreview()?.currentPreviewItem?.previewItemURL)
            #expect(FileManager.default.fileExists(atPath: previewURL.path))
            #expect(try Data(contentsOf: previewURL) == Data("The source now exists.".utf8))
            try await capture(try #require(visiblePreview()?.contentView), name: "attachment-preview-before-failed-removal")

            try file.refuse("DELETE", on: "outgoingAttachment")
            refusesRemoval = true
            try await press("Remove retry.txt", in: host.root)
            try await until { host.model.failedAttachments.first?.isRemoval == true }
            #expect(host.model.attachments.count == 1)
            #expect(FileManager.default.fileExists(atPath: previewURL.path),
                    "A failed removal must retain the file used by the current preview")
            #expect((try? Data(contentsOf: previewURL)) == Data("The source now exists.".utf8))
            try await capture(host.root, name: "attachment-removal-failed")
            try await press("Keep", in: host.root)
            try await until { host.model.failedAttachments.isEmpty }
            #expect(host.model.attachments.count == 1)
            #expect(FileManager.default.fileExists(atPath: previewURL.path))
            try await press("Open retry.txt", in: host.root)
            try await until { visiblePreview()?.currentPreviewItem?.previewItemURL == previewURL }
            #expect(try Data(contentsOf: previewURL) == Data("The source now exists.".utf8))
            try await capture(try #require(visiblePreview()?.contentView), name: "attachment-preview-retained-after-keep")
            try await closePreview()
            try await until { visiblePreview() == nil }
            #expect(host.window.isVisible, "Closing Quick Look must leave the failure-test compose window open")

            try await press("Remove retry.txt", in: host.root)
            try await until { host.model.failedAttachments.first?.isRemoval == true }
            try file.allow("DELETE", on: "outgoingAttachment")
            refusesRemoval = false
            try await press("Retry", in: host.root)
            try await until { host.model.failedAttachments.isEmpty && host.model.attachments.isEmpty }
            try await capture(host.root, name: "attachment-removal-retry-succeeded")
            await mailbox.stop()
            print("TERN_ATTACHMENT_AUDIT failure-retry-remove-keep-passed")
        }
    }

    @Test func removalDuringSuspendedCopyDoesNotRecreatePreviewFile() async throws {
        try requireSyntheticAudit()
        try await withPreviewCleanup {
            for closesWindow in [false, true] {
                let draftID = "attachment-copy-race-\(UUID().uuidString)"
                var attachment = OutgoingAttachment(localDraftID: draftID, filename: "race.txt",
                                                    mimeType: "text/plain", size: 4, path: "unused")
                attachment.id = 1
                let files = OutgoingAttachmentFiles(localDraftID: draftID)
                var continuation: CheckedContinuation<Data, Never>?
                let copying = Task { @MainActor [attachment] in
                    await files.url(for: attachment) {
                        await withCheckedContinuation { continuation = $0 }
                    }
                }
                defer {
                    continuation?.resume(returning: Data())
                    files.removeAll()
                }
                try await until { continuation != nil }
                if closesWindow { files.removeAll() } else { files.remove(attachment) }
                continuation?.resume(returning: Data("Race".utf8))
                continuation = nil
                let result = await copying.value
                #expect(result == nil, "A suspended copy must not publish a URL after removal or close")
                let folder = FileManager.default.temporaryDirectory.appending(path: "Tern/Compose/\(draftID)")
                let children = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
                #expect(!children.contains { $0.hasSuffix("race.txt") }, "A removed attachment's preview file must not reappear")
            }
        }
    }

    @Test func removedAttachmentCannotOpenAfterSuspendedPreviewResumes() async throws {
        try requireSyntheticAudit()
        try await withPreviewCleanup {
            let directory = FileManager.default.temporaryDirectory.appending(path: "AttachmentPreviewRace-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "race.txt")
            try Data("Preview race fixture.".utf8).write(to: file)
            var attachment = OutgoingAttachment(localDraftID: "preview-race", filename: "race.txt",
                                                mimeType: "text/plain", size: 21, path: "unused")
            attachment.id = 1
            let state = AttachmentPreviewRaceState(attachment: attachment)
            let controller = NSHostingController(rootView: AttachmentPreviewRaceHost(state: state))
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 200))
            window.makeKeyAndOrderFront(nil)
            defer {
                state.continuation?.resume(returning: nil)
                window.close()
                window.contentViewController = nil
                try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(for: .milliseconds(100))
            try await press("Open race.txt", in: controller.view)
            try await until { state.continuation != nil }
            try await press("Remove race.txt", in: controller.view)
            try await until { state.attachments.isEmpty }
            state.continuation?.resume(returning: file)
            state.continuation = nil
            try await Task.sleep(for: .milliseconds(500))
            let selectedName = visiblePreview()?.currentPreviewItem?.previewItemURL?.lastPathComponent
            print("TERN_ATTACHMENT_AUDIT removed-race-preview=\(selectedName ?? "none")")
            if selectedName == "race.txt", let content = visiblePreview()?.contentView {
                try await capture(content, name: "attachment-removed-preview-resurrected")
            }
            #expect(selectedName != "race.txt", "The removed fixture must not be selected by its stale request")
            #expect(visiblePreview() == nil, "An old preview task must not open an attachment removed while it was loading")
        }
    }

    @Test func laterPreviewRequestKeepsSelectionWhenEarlierRequestFinishes() async throws {
        try requireSyntheticAudit()
        try await withPreviewCleanup {
            let directory = FileManager.default.temporaryDirectory.appending(path: "AttachmentPreviewOrder-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let firstURL = directory.appending(path: "first.txt")
            let latestURL = directory.appending(path: "latest.txt")
            try Data("First preview.".utf8).write(to: firstURL)
            try Data("Latest preview.".utf8).write(to: latestURL)
            var first = OutgoingAttachment(localDraftID: "preview-order", filename: "first.txt",
                                           mimeType: "text/plain", size: 14, path: "unused")
            var latest = OutgoingAttachment(localDraftID: "preview-order", filename: "latest.txt",
                                            mimeType: "text/plain", size: 15, path: "unused")
            first.id = 1
            latest.id = 2
            let state = AttachmentPreviewRaceState(attachments: [first, latest], readyURLs: [1: firstURL, 2: latestURL])
            let controller = NSHostingController(rootView: AttachmentPreviewRaceHost(state: state))
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 200))
            window.makeKeyAndOrderFront(nil)
            defer {
                state.continuation?.resume(returning: nil)
                window.close()
                window.contentViewController = nil
                try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(for: .milliseconds(100))
            try await press("Open first.txt", in: controller.view)
            try await until { state.continuation != nil }
            try await press("Open latest.txt", in: controller.view)
            try await until { visiblePreview()?.currentPreviewItem?.previewItemURL == latestURL }
            state.continuation?.resume(returning: firstURL)
            state.continuation = nil
            try await Task.sleep(for: .milliseconds(500))
            let selectedURL = visiblePreview()?.currentPreviewItem?.previewItemURL
            print("TERN_ATTACHMENT_AUDIT ordered-preview=\(selectedURL?.lastPathComponent ?? "none")")
            #expect(visiblePreview()?.currentPreviewItem?.previewItemURL == latestURL,
                    "Finishing an earlier request must not replace the attachment the user opened last")
            try await capture(try #require(visiblePreview()?.contentView),
                        name: selectedURL == latestURL ? "attachment-latest-preview-retained" : "attachment-stale-preview-overrode-latest")
        }
    }

    private func requireSyntheticAudit() throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--attachment-audit"))
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"), "Attachment checks require synthetic accounts")
    }

    private func composeHost(app: AppModel, mailbox: MailboxModel) async throws -> AttachmentComposeHost {
        let id = try #require(await mailbox.startCompose(.newMessage))
        let closer = ComposeWindowCloser()
        let controller = NSHostingController(rootView: ComposeView(localDraftID: id, mailbox: mailbox,
            isEdited: .constant(false), closer: closer, onMove: { _ in }).environment(app))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 780, height: 720))
        window.makeKeyAndOrderFront(nil)
        try await until { closer.model?.phase == .open }
        return AttachmentComposeHost(window: window, controller: controller, model: try #require(closer.model))
    }

    private func visiblePreview() -> QLPreviewPanel? {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return nil }
        return panel
    }

    private func closePreview() async throws {
        guard let panel = visiblePreview() else { return }
        if ProcessInfo.processInfo.arguments.contains("--attachment-live") {
            let filename = panel.currentPreviewItem?.previewItemURL?.lastPathComponent ?? "unknown"
            print("TERN_ATTACHMENT_AUDIT waiting-for-native-close \(filename)")
            let deadline = ContinuousClock.now + .seconds(120)
            while panel.isVisible, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(!panel.isVisible, "Close the actual Quick Look panel using its native control")
            print("TERN_ATTACHMENT_AUDIT native-close-observed")
            return
        }
        // Nonlive race tests use this only for isolation after their assertions.
        // Native close behavior is verified exclusively by the live acceptance tests.
        panel.orderOut(nil)
        try await until { visiblePreview() == nil }
    }

    private func withPreviewCleanup(_ operation: () async throws -> Void) async throws {
        try await closePreview()
        do {
            try await operation()
        } catch {
            let originalError = error
            do { try await closePreview() } catch { Issue.record("Attachment preview cleanup failed: \(error)") }
            throw originalError
        }
        try await closePreview()
    }

    private func sendKey(_ characters: String, code: UInt16, to window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil)
        if let panel = window as? QLPreviewPanel {
            try #require(visiblePreview() === panel)
        }
        let modifiers: NSEvent.ModifierFlags = (123...126).contains(code) ? [.function, .numericPad] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            try #require(event.windowNumber == window.windowNumber)
            window.sendEvent(event)
        }
    }

    private func until(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func press(_ label: String, in root: NSView) async throws {
        var seen = Set<ObjectIdentifier>()
        let selector = NSSelectorFromString("accessibilityPerformPress")
        func find(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func attribute(_ name: String) -> Any? {
                object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
            }
            if attribute("accessibilityLabel") as? String == label, object.responds(to: selector) { return object }
            let children = attribute("accessibilityChildren") as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let result = find(child) { return result }
            }
            return nil
        }
        try await until {
            seen.removeAll()
            return find(root) != nil
        }
        seen.removeAll()
        let object = try #require(find(root), "Missing native control: \(label)")
        let implementation = try #require(object.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        try #require(unsafeBitCast(implementation, to: Press.self)(object, selector))
    }

    private func capture(_ view: NSView, name: String) async throws {
        // Let SwiftUI render the model change and finish the existing chip transition.
        try await Task.sleep(for: .milliseconds(350))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name + ".png")
    }
}

@MainActor
private final class AttachmentComposeHost {
    let window: NSWindow
    let controller: NSViewController
    let model: ComposeModel
    var root: NSView { controller.view }

    init(window: NSWindow, controller: NSViewController, model: ComposeModel) {
        self.window = window
        self.controller = controller
        self.model = model
    }

    func close() {
        window.close()
        window.contentViewController = nil
    }
}

@MainActor
private final class AttachmentPreviewRaceState: ObservableObject {
    @Published var attachments: [OutgoingAttachment]
    var continuation: CheckedContinuation<URL?, Never>?
    private let readyURLs: [Int64: URL]
    private var hasSuspendedRequest = false

    convenience init(attachment: OutgoingAttachment) { self.init(attachments: [attachment], readyURLs: [:]) }

    init(attachments: [OutgoingAttachment], readyURLs: [Int64: URL]) {
        self.attachments = attachments
        self.readyURLs = readyURLs
    }

    func fileURL(_ attachment: OutgoingAttachment) async -> URL? {
        if readyURLs.isEmpty || !hasSuspendedRequest {
            hasSuspendedRequest = true
            return await withCheckedContinuation { continuation = $0 }
        }
        return attachment.id.flatMap { readyURLs[$0] }
    }
}

private struct AttachmentPreviewRaceHost: View {
    @ObservedObject var state: AttachmentPreviewRaceState

    var body: some View {
        AttachmentStrip(attachments: state.attachments, failed: [], isEditable: true,
            fileURL: { await state.fileURL($0) }, retry: { _ in }, dismissFailure: { _ in }) { attachment in
                state.attachments.removeAll { $0.id == attachment.id }
            }
    }
}
