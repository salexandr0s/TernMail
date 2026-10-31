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
    /// The toolbar is short of room, so an idle field folds into a button
    /// rather than pushing the assistant into the overflow menu.
    var isFolded = false

    var body: some CustomizableToolbarContent {
        // Keeps the field out of the capsule of the actions before it.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "workspace.search", placement: .primaryAction) {
            WorkspaceSearchItem(
                placeholder: placeholder, text: text, focusRequest: focusRequest,
                width: isCompact ? Tokens.Layout.searchMinWidth : Tokens.Layout.searchWidth, canFold: isFolded,
                onChange: update, onSubmit: submit, onCancel: cancel
            )
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

/// The field, or while it's folded, a button that opens it. An opened field
/// takes focus and folds again once it's left empty.
private struct WorkspaceSearchItem: View {
    let placeholder: String
    let text: String
    let focusRequest: Int
    let width: CGFloat
    let canFold: Bool
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @State private var isOpen = false

    var body: some View {
        if canFold && text.isEmpty && !isOpen {
            Button(placeholder, systemImage: "magnifyingglass") { isOpen = true }
                .labelStyle(.iconOnly)
                // ⌥⌘F and Find open the field when it's folded.
                .onChange(of: focusRequest) { _, _ in isOpen = true }
        } else {
            WorkspaceSearchField(
                placeholder: placeholder, text: text, focusRequest: focusRequest, focusesOnAppear: isOpen,
                onChange: onChange, onSubmit: onSubmit, onCancel: onCancel,
                onEndEditing: { isOpen = false }
            )
            .frame(width: width)
        }
    }
}

private struct WorkspaceSearchField: NSViewRepresentable {
    let placeholder: String
    let text: String
    let focusRequest: Int
    var focusesOnAppear = false
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var onEndEditing: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusingSearchField()
        field.focusesOnAppear = focusesOnAppear
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
        coordinator.onEndEditing = onEndEditing
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
        var onEndEditing: () -> Void = {}

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

        func controlTextDidEndEditing(_ notification: Notification) {
            onEndEditing()
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

/// A field opened from its folded button takes focus once it's in a window.
private final class FocusingSearchField: NSSearchField {
    var focusesOnAppear = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusesOnAppear, let window else { return }
        focusesOnAppear = false
        window.makeFirstResponder(self)
    }
}
