import AppKit
import MessageContent
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct DesignComposeLayoutTests {
    @Test func shortWindowsReserveWritingSpaceAfterNoticesAndFormatting() {
        for height: CGFloat in [300, 360, 540, 800] {
            for formatting: CGFloat in [0, 36, 64] {
                let budget = ComposeLayoutBudget(availableHeight: height, headerHeight: 2_400,
                    supplementHeight: 1_200, formattingHeight: formatting,
                    editorMinimum: 128, dividerHeight: 1)
                #expect(budget.editor >= 128)
                #expect(budget.header > 0 && budget.supplements > 0)
                #expect(abs(budget.header + budget.editor + budget.supplements + formatting + 1 - height) < 0.01)
            }
        }
        let compact = ComposeLayoutBudget(availableHeight: 540, headerHeight: 120,
            supplementHeight: 32, formattingHeight: 0, editorMinimum: 128, dividerHeight: 1)
        #expect(compact.header == 120 && compact.supplements == 32)
        #expect(compact.editor == 387, "Small supporting regions must release unused height to the writer")
    }

    @Test func nativeEditingSurvivesRecipientOverflowResizeAndInputComposition() async throws {
        let fixture = try await DesignComposeVisualAudit.Fixture.make()
        defer { fixture.dispose() }
        try await fixture.stress()
        try fixture.assertWritingViewport()
        let body = try fixture.bodyEditor()
        let nativeIdentity = ObjectIdentifier(body)
        let bcc = try fixture.recipient("Bcc")
        try await fixture.focusRecipient(bcc)
        try fixture.assertCaretVisible(in: bcc)
        let recipientEditor = try #require(bcc.currentEditor() as? NSTextView)
        recipientEditor.setMarkedText("測試", selectedRange: NSRange(location: 2, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedRange = recipientEditor.markedRange()
        let selection = recipientEditor.selectedRange()
        fixture.window.setContentSize(NSSize(width: 600, height: 400))
        try await fixture.settle()
        #expect(bcc.currentEditor() === recipientEditor)
        #expect(recipientEditor.hasMarkedText())
        #expect(recipientEditor.markedRange() == markedRange && recipientEditor.selectedRange() == selection)
        try fixture.assertCaretVisible(in: bcc)
        recipientEditor.unmarkText()
        recipientEditor.inputContext?.discardMarkedText()
        try await fixture.settle()
        try #require(!recipientEditor.hasMarkedText())

        let focusedBody = try await fixture.focusBodyForTyping()
        try #require(focusedBody === body)
        body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        body.breakUndoCoalescing()
        let before = body.string
        let inserted = " Latest native edit."
        let typed = before + inserted
        body.insertText(inserted, replacementRange: body.selectedRange())
        body.breakUndoCoalescing()
        try #require(body.string == typed && body.textStorage?.string == typed,
            "Native insertion must contain the requested literal before resizing or accepting an undo snapshot")
        try #require(fixture.model.content.body.plainText().hasSuffix(inserted),
            "The inserted literal must reach the production draft before resizing")
        fixture.window.setContentSize(NSSize(width: 480, height: 360))
        try await fixture.settle()
        #expect(ObjectIdentifier(try fixture.bodyEditor()) == nativeIdentity)
        #expect(body.string == typed)
        try fixture.assertWritingViewport()
        try #require(body.undoManager?.canUndo == true)
        body.undoManager?.undo()
        try await fixture.settle()
        #expect(body.string == before)
        try #require(body.undoManager?.canRedo == true)
        body.undoManager?.redo()
        try await fixture.settle()
        #expect(body.string == typed)

        // Toolbar state changes must keep the native editor/selection alive too.
        let bodySelection = body.selectedRange()
        try await fixture.press(id: "compose-formatting-toggle")
        try await fixture.waitUntil { !fixture.model.showsFormatting }
        try await fixture.settle()
        #expect(ObjectIdentifier(try fixture.bodyEditor()) == nativeIdentity)
        #expect(body.string == typed && body.selectedRange() == bodySelection)
        try fixture.assertWritingViewport()
        try fixture.scrollSupplementsToBottom()
        try await fixture.settle()
        try await fixture.revealControl(id: "compose-edit-quote")
        try fixture.assertVisible(id: "compose-edit-quote")
        await fixture.model.requestClose()
        await fixture.mailbox.stop()
    }

    @Test(arguments: ["save", "send", "close"])
    func boundedProductionFormPreservesLatestTypingForImmediateActions(action: String) async throws {
        let fixture = try await DesignComposeVisualAudit.Fixture.make()
        defer { fixture.dispose() }
        fixture.model.content.to = [.init(address: "recipient@example.invalid")]
        fixture.model.content.subject = "Native draft action"
        let body = try await fixture.focusBodyForTyping()
        body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        let inserted = "Latest input before \(action)."
        let expectedText = body.string + inserted
        body.insertText(inserted, replacementRange: body.selectedRange())
        try #require(body.string == expectedText && body.textStorage?.string == expectedText,
            "Native insertion must contain the requested literal before an immediate draft action")
        let expected = AttributedDocument.document(from: try #require(body.textStorage))
        try #require(expected.plainText().contains(inserted), "The expected document must include the inserted literal")
        #expect(fixture.model.content.body == expected, "Native typing must reach the model before awaiting the control action")
        switch action {
        case "send":
            // Use the actual extracted toolbar button, including its Task boundary.
            try await fixture.press(id: "compose-send")
            try await fixture.waitUntil { fixture.model.phase == .closed }
        case "save":
            fixture.model.save()
            try await fixture.waitUntil { fixture.model.status?.text == "Saved to Drafts" }
        default:
            await fixture.model.requestClose()
        }
        let id = fixture.model.localDraftID
        let stored = try #require(try await fixture.cache.read { try $0.localDraft(id: id) })
        #expect(stored.body == expected)
        if action == "save" { await fixture.model.requestClose() }
        await fixture.mailbox.stop()
    }
}
