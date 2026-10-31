import AppKit
import SwiftUI

/// The window's search field. It searches whatever the window shows: mail,
/// events or attachments. ⌥⌘F and Find focus it.
///
/// This is an `NSSearchField`, not `.searchable`. On macOS 26 the system
/// search item inside a customizable toolbar rebuilds the toolbar on every
/// layout pass, and the window never finishes opening.
struct WorkspaceSearchToolbar: CustomizableToolbarContent {
    let mailbox: MailboxModel
    let calendar: CalendarModel
    let libraryToolbar: AttachmentLibraryToolbarState
    let section: WorkspaceSection
    var isCompact = false

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "workspace.search", placement: .primaryAction) {
            WorkspaceSearchField(
                placeholder: placeholder, text: text, focusRequest: focusRequest,
                onChange: update, onSubmit: submit, onCancel: cancel
            )
            .frame(width: isCompact ? Tokens.Layout.searchMinWidth : Tokens.Layout.searchWidth)
            .help(help)
        }
        .customizationBehavior(.disabled)
    }

    private var placeholder: String {
        switch section {
        case .mail: "Search mail"
        case .calendar: "Search events"
        case .attachments: "Search attachments"
        }
    }

    private var help: String {
        switch section {
        case .mail: "Search mail (\(ShortcutCatalog.searchMail.label)). Return searches Gmail."
        case .calendar: "Search events (\(ShortcutCatalog.find.label))"
        case .attachments: "Search attachments (\(ShortcutCatalog.find.label))"
        }
    }

    private var text: String {
        switch section {
        case .mail: mailbox.search.text
        case .calendar: calendar.searchText
        case .attachments: libraryToolbar.searchText
        }
    }

    private var focusRequest: Int {
        switch section {
        case .mail: mailbox.search.fieldFocusRequest
        case .calendar: calendar.searchFocusRequest
        case .attachments: libraryToolbar.searchFocusRequest
        }
    }

    private func update(_ text: String) {
        switch section {
        case .mail: mailbox.search.update(text)
        case .calendar: calendar.searchText = text
        case .attachments: libraryToolbar.searchText = text
        }
    }

    private func submit() {
        if section == .mail { mailbox.search.submit() }
    }

    private func cancel() {
        switch section {
        case .mail: mailbox.search.cancel()
        case .calendar: calendar.searchText = ""
        case .attachments: libraryToolbar.searchText = ""
        }
    }
}

private struct WorkspaceSearchField: NSViewRepresentable {
    let placeholder: String
    let text: String
    let focusRequest: Int
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.textChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        coordinator.onSubmit = onSubmit
        coordinator.onCancel = onCancel
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(placeholder)
        }
        if field.stringValue != text { field.stringValue = text }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(focusRequest: focusRequest, onChange: onChange, onSubmit: onSubmit, onCancel: onCancel)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var focusRequest: Int
        var onChange: (String) -> Void
        var onSubmit: () -> Void
        var onCancel: () -> Void

        init(focusRequest: Int, onChange: @escaping (String) -> Void,
             onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.focusRequest = focusRequest
            self.onChange = onChange
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        @objc func textChanged(_ sender: NSSearchField) {
            onChange(sender.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}
