import AppKit
import MessageContent
import SwiftUI

/// A To, Cc or Bcc field: each address is a token, completed from the
/// addresses in stored mail. An address that isn't valid shows as plain text.
struct RecipientField: NSViewRepresentable {
    let label: String
    @Binding var addresses: [EmailAddress]
    /// Set to move the cursor here. The field clears it once it has the cursor.
    @Binding var requestsFocus: Bool
    var isEditable: Bool
    let suggestions: @MainActor (String) async -> [EmailAddress]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",;")
        field.completionDelay = 0.1
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(label)
        context.coordinator.field = field
        context.coordinator.show(addresses)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        field.isEditable = isEditable
        if addresses != context.coordinator.shownAddresses {
            context.coordinator.show(addresses)
        }
        if requestsFocus {
            // Changing focus or the binding during a view update isn't allowed.
            Task { @MainActor in
                field.window?.makeFirstResponder(field)
                requestsFocus = false
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTokenField, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let cell = field.cell else { return nil }
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return CGSize(width: width, height: ceil(cell.cellSize(forBounds: bounds).height))
    }

    /// The text that edits an address, and that copying a token puts on the pasteboard.
    static func editingString(_ address: EmailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.address }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" <\(address.address)>"
    }

    /// The address in one token. Tokens hold objects, not values.
    final class Token: NSObject {
        let address: EmailAddress

        init(_ address: EmailAddress) {
            self.address = address
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: RecipientField
        weak var field: NSTokenField?
        /// What the field shows, so updates that come back from the binding leave it alone.
        private(set) var shownAddresses: [EmailAddress] = []
        private var loadedQuery: String?
        private var loaded: [EmailAddress] = []
        /// Completion strings and the addresses they stand for. A name's commas
        /// are left out of its completion string, since a comma ends a token.
        private var completions: [String: EmailAddress] = [:]
        private var loadTask: Task<Void, Never>?

        init(_ parent: RecipientField) {
            self.parent = parent
        }

        func show(_ addresses: [EmailAddress]) {
            shownAddresses = addresses
            field?.objectValue = addresses.map(Token.init)
        }

        // MARK: NSTokenFieldDelegate

        func controlTextDidChange(_ notification: Notification) {
            publish()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            publish()
        }

        func tokenField(
            _ tokenField: NSTokenField,
            completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            let query = substring.trimmingCharacters(in: .whitespaces).lowercased()
            guard !query.isEmpty else { return [] }
            if query == loadedQuery {
                // Return picks the first match for a name, but never replaces an address being typed.
                selectedIndex?.pointee = query.contains("@") || loaded.isEmpty ? -1 : 0
                return loaded.map(completionString)
            }
            loadTask?.cancel()
            let suggestions = parent.suggestions
            loadTask = Task { [weak self, weak tokenField] in
                let results = await suggestions(query)
                guard let self, !Task.isCancelled else { return }
                loadedQuery = query
                loaded = results
                // Asks again for completions, which now come from `loaded`.
                if !results.isEmpty, let editor = tokenField?.currentEditor() as? NSTextView {
                    editor.complete(nil)
                }
            }
            return []
        }

        func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
            let text = editingString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let address = completions[text] { return Token(address) }
            return Token(EmailAddress.parseList(text).first ?? EmailAddress(address: text))
        }

        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject object: Any) -> String? {
            guard let token = object as? Token else { return object as? String }
            if let name = token.address.name, !name.isEmpty { return name }
            return token.address.address
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject object: Any) -> String? {
            (object as? Token).map { RecipientField.editingString($0.address) } ?? object as? String
        }

        func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject object: Any) -> NSTokenField.TokenStyle {
            (object as? Token)?.address.isValid == true ? .default : .none
        }

        func tokenField(_ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pasteboard: NSPasteboard) -> Bool {
            let text = objects
                .compactMap { ($0 as? Token).map { RecipientField.editingString($0.address) } ?? $0 as? String }
                .joined(separator: ", ")
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }

        // MARK: Private

        private func completionString(_ address: EmailAddress) -> String {
            let name = address.name?.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ";", with: "")
            let string = name.map { "\($0) <\(address.address)>" } ?? address.address
            completions[string] = address
            return string
        }

        /// Tokens, then any text still being typed.
        private func publish() {
            guard let field else { return }
            let objects = field.objectValue as? [Any] ?? []
            let addresses = objects.flatMap { object -> [EmailAddress] in
                if let token = object as? Token { return [token.address] }
                guard let text = (object as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    return []
                }
                let parsed = EmailAddress.parseList(text)
                return parsed.isEmpty ? [EmailAddress(address: text)] : parsed
            }
            shownAddresses = addresses
            if parent.addresses != addresses { parent.addresses = addresses }
        }
    }
}
