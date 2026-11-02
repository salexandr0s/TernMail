import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

/// Hosts production controls with the existing synthetic account fixture.
@Suite(.serialized) @MainActor struct MotionInteractionTests {
    @Test
    func composerDisclosuresKeepFocusAndAttachmentActions() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let id = try #require(await mailbox.startCompose(.newMessage))
        let closer = ComposeWindowCloser()
        let controller = NSHostingController(rootView: ComposeView(localDraftID: id, mailbox: mailbox,
            isEdited: .constant(false), closer: closer, onMove: { _ in })
            .environment(app))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 720))
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentViewController = nil }
        let root = controller.view
        try await until { closer.model?.phase == .open }
        let model = try #require(closer.model)
        try await until {
            self.descendants(root).compactMap { $0 as? RecipientTokenField }
                .contains { $0.accessibilityLabel() == "To" && $0.currentEditor() != nil }
        }
        for (action, label) in [("Add Cc Recipients", "Cc"), ("Add Bcc Recipients", "Bcc")] {
            try press(action, in: root)
            try await until {
                self.descendants(root).compactMap { $0 as? RecipientTokenField }
                    .contains { $0.accessibilityLabel() == label && $0.currentEditor() != nil
                        && $0.currentEditor() === window.firstResponder }
            }
        }
        model.attach([
            .data(Data("Agenda".utf8), filename: "agenda.txt", mimeType: "text/plain"),
            .data(Data("Notes".utf8), filename: "notes.txt", mimeType: "text/plain")
        ])
        try await until { model.attachments.count == 2 }
        try await Task.sleep(for: .milliseconds(40))
        try capture(root, name: "compose-arrival-40ms")
        try await Task.sleep(for: .milliseconds(240))
        try capture(root, name: "compose-attachments")
        try press("Remove agenda.txt", in: root)
        try await until { model.attachments.count == 1 }
        #expect(model.attachments.first?.filename == "notes.txt")
        try await Task.sleep(for: .milliseconds(40))
        try capture(root, name: "compose-removal-40ms")
        try await Task.sleep(for: .milliseconds(240))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: appearance == .aqua ? 640 : 780, height: 720))
            try await Task.sleep(for: .milliseconds(100))
            try capture(root, name: "compose-result-\(appearance.rawValue)")
        }
    }

    @Test
    func mailActionsAndNoticeReplacementStayUsable() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        try await until {
            mailbox.presentedAccounts.count == 2 && mailbox.presentedAccounts.allSatisfy(\.hasSyncedOnce)
        }
        mailbox.selectedMailbox = .account("ui-audit", SystemLabel.inbox)
        try await until { mailbox.isListPresentationReady && !mailbox.listItems.isEmpty }
        let item = try #require(mailbox.listItems.first)
        mailbox.selectListRows([item.id])
        let controller = NSHostingController(rootView: ThreadListView(mailbox: mailbox)
            .modifier(MailNoticeOverlay(mailbox: mailbox))
            .environment(app))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 440, height: 640))
        window.orderFront(nil)
        defer { window.close(); window.contentViewController = nil }
        try await Task.sleep(for: .milliseconds(200))
        let root = controller.view
        try press(item.thread.isStarred ? "Remove Star" : "Star", in: root, rowSubject: item.thread.subject)
        try await until { mailbox.listItems.first { $0.id == item.id }?.thread.isStarred == !item.thread.isStarred }
        let archive = try #require(mailbox.perform(.archive, on: [item.id.threadKey]))
        await archive.value
        try await until { !mailbox.listItems.contains { $0.id == item.id } && mailbox.notice?.undo != nil }
        try press("Undo", in: root)
        try await until { mailbox.listItems.contains { $0.id == item.id } && mailbox.notice == nil }
        mailbox.notice = .init(message: "Conversation archived", duration: .milliseconds(180))
        try await Task.sleep(for: .milliseconds(40))
        try capture(root, name: "notice-arrival-40ms")
        mailbox.notice = .init(message: "Labels updated", duration: .seconds(10))
        let replacementID = mailbox.notice?.id
        try await Task.sleep(for: .milliseconds(280))
        #expect(mailbox.notice?.id == replacementID, "An exiting notice must not dismiss its replacement")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(100))
            try capture(root, name: "mail-result-\(appearance.rawValue)")
        }
        try press("Dismiss", in: root)
        try await until { mailbox.notice == nil }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--reduce-motion-audit")),
          .timeLimit(.minutes(5)))
    func realReduceMotionBlocksInheritedAnimationAndKeepsActionsUsable() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        try #require(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                     "Enable the real macOS Reduce Motion setting before this audit")
        let state = RuntimeMotionProbeState()
        let controller = NSHostingController(rootView: RuntimeMotionProbe(state: state))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 120))
        window.orderFront(nil)
        defer { window.close(); window.contentViewController = nil }

        try await until { state.observedReduceMotion == true }
        try await verifyInheritedAnimation(state, reducesMotion: true)
        try await composerDisclosuresKeepFocusAndAttachmentActions()
        try await replyQuoteDisclosureKeepsQuotedContent()
        try await mailActionsAndNoticeReplacementStayUsable()
        print("TERN_REDUCE_MOTION_AUDIT reduced-actions-passed")

        if ProcessInfo.processInfo.arguments.contains("--reduce-motion-live") {
            print("TERN_REDUCE_MOTION_AUDIT waiting-for-off")
            try await waitForLiveSetting(false, state: state)
            try await verifyInheritedAnimation(state, reducesMotion: false)
            print("TERN_REDUCE_MOTION_AUDIT waiting-for-on")
            try await waitForLiveSetting(true, state: state)
            try await verifyInheritedAnimation(state, reducesMotion: true)
            print("TERN_REDUCE_MOTION_AUDIT live-settings-passed")
        }
    }

    private func verifyInheritedAnimation(_ state: RuntimeMotionProbeState, reducesMotion: Bool) async throws {
        let previousOffset = state.offset
        let nextOffset = previousOffset + 48
        state.renderedOffsets.removeAll()
        withAnimation(Tokens.Motion.standard(duration: 1)) { state.offset = nextOffset }
        try await until { state.samples.contains { $0.offset == nextOffset } }
        let sample = try #require(state.samples.last { $0.offset == nextOffset })
        try #require(sample.reducesMotion == reducesMotion)
        print("TERN_REDUCE_MOTION_AUDIT reduce=\(sample.reducesMotion) inherited-animation=\(sample.hasAnimation) disables-animations=\(sample.disablesAnimations)")
        try await Task.sleep(for: .milliseconds(120))
        let intermediateCount = state.renderedOffsets.filter {
            $0 > previousOffset + 0.01 && $0 < nextOffset - 0.01
        }.count
        if reducesMotion {
            try #require(state.renderedOffsets.contains { abs($0 - nextOffset) < 0.01 },
                         "The reduced-motion update must render its final position")
        }
        print("TERN_REDUCE_MOTION_AUDIT reduce=\(reducesMotion) intermediate-offsets=\(intermediateCount)")
        try #require(reducesMotion ? intermediateCount == 0 : intermediateCount > 0,
                     "The rendered offset must jump under Reduce Motion and interpolate with motion enabled")
        try #require(sample.hasAnimation == !reducesMotion,
                     "Reduce Motion must clear inherited animation even when ternAnimation's watched value is unchanged")
        if !reducesMotion { try await Task.sleep(for: .seconds(1)) }
    }

    private func replyQuoteDisclosureKeepsQuotedContent() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        try await until { mailbox.hasSyncedOnce }
        // AuditGmail's first account contains m1, the synthetic Field notes message.
        let id = try #require(await mailbox.startCompose(.reply(.reply, messageID: "m1", accountID: "ui-audit")))
        let closer = ComposeWindowCloser()
        let controller = NSHostingController(rootView: ComposeView(localDraftID: id, mailbox: mailbox,
            isEdited: .constant(false), closer: closer, onMove: { _ in }).environment(app))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 720))
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentViewController = nil }
        try await until { closer.model?.phase == .open }
        let model = try #require(closer.model)
        let quote = try #require(model.draft?.quotedPlainText)
        try #require(!quote.isEmpty)
        let root = controller.view
        try press("Show Quoted Text", in: root)
        try await Task.sleep(for: .milliseconds(40))
        try capture(root, name: "reply-quote-expanded-40ms")
        // The opposite action is exposed only after the production disclosure changes state.
        try press("Hide Quoted Text", in: root)
        try await Task.sleep(for: .milliseconds(40))
        try capture(root, name: "reply-quote-collapsed-40ms")
        #expect(model.draft?.quotedPlainText == quote)
        print("TERN_REDUCE_MOTION_AUDIT quote-disclosure-passed")
    }

    private func waitForLiveSetting(_ enabled: Bool, state: RuntimeMotionProbeState) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion != enabled
               || state.observedReduceMotion != enabled), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == enabled)
        try #require(state.observedReduceMotion == enabled,
                     "The existing SwiftUI host must observe the live system setting")
    }

    private func until(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func press(_ label: String, in root: NSView, rowSubject: String? = nil) throws {
        var seen = Set<ObjectIdentifier>()
        var customAction: NSAccessibilityCustomAction?
        let selector = NSSelectorFromString("accessibilityPerformPress")
        func find(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func attribute(_ name: String) -> Any? {
                object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
            }
            if let rowSubject,
               (attribute("accessibilityLabel") as? String)?.contains(rowSubject) == true,
               let action = (attribute("accessibilityCustomActions") as? [NSAccessibilityCustomAction])?.first(where: { $0.name == label }) {
                customAction = action
                return object
            }
            if rowSubject == nil, attribute("accessibilityLabel") as? String == label, object.responds(to: selector) { return object }
            let children = attribute("accessibilityChildren") as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let result = find(child) { return result }
            }
            return nil
        }
        let object = try #require(find(root), "Missing control: \(label)")
        if let customAction {
            if let handler = customAction.handler {
                try #require(handler())
            } else {
                let target = try #require(customAction.target as? NSObject)
                let action = try #require(customAction.selector)
                let implementation = try #require(target.method(for: action))
                if NSStringFromSelector(action).contains(":") {
                    typealias Invoke = @convention(c) (AnyObject, Selector, NSAccessibilityCustomAction) -> Bool
                    try #require(unsafeBitCast(implementation, to: Invoke.self)(target, action, customAction))
                } else {
                    typealias Invoke = @convention(c) (AnyObject, Selector) -> Bool
                    try #require(unsafeBitCast(implementation, to: Invoke.self)(target, action))
                }
            }
            return
        }
        let implementation = try #require(object.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        try #require(unsafeBitCast(implementation, to: Press.self)(object, selector))
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name + ".png")
    }
}

@MainActor
private final class RuntimeMotionProbeState: ObservableObject {
    struct Sample {
        let offset: CGFloat
        let reducesMotion: Bool
        let hasAnimation: Bool
        let disablesAnimations: Bool
    }

    @Published var offset: CGFloat = 0
    var observedReduceMotion: Bool?
    var samples: [Sample] = []
    var renderedOffsets: [CGFloat] = []
}

private struct RuntimeMotionProbe: View {
    @ObservedObject var state: RuntimeMotionProbeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 80, height: 40)
            .background(RuntimeMotionTransactionView(state: state, offset: state.offset, reducesMotion: reduceMotion))
            .modifier(RuntimeMotionOffset(offset: state.offset, state: state))
            // An unrelated outer animation must also respect the real setting.
            .ternAnimation(value: false)
    }
}

private struct RuntimeMotionTransactionView: NSViewRepresentable {
    let state: RuntimeMotionProbeState
    let offset: CGFloat
    let reducesMotion: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        state.observedReduceMotion = reducesMotion
        state.samples.append(.init(offset: offset, reducesMotion: reducesMotion,
                                   hasAnimation: context.transaction.animation != nil,
                                   disablesAnimations: context.transaction.disablesAnimations))
    }
}

private struct RuntimeMotionOffset: AnimatableModifier {
    nonisolated var offset: CGFloat
    let state: RuntimeMotionProbeState

    nonisolated var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        state.renderedOffsets.append(offset)
        return content.offset(x: offset)
    }
}
