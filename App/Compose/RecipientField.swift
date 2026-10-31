import AppKit
import MailStore
import MessageContent
import SwiftUI

/// A To, Cc or Bcc field: each address is a token, completed from the
/// addresses in stored mail. An address that isn't valid shows as plain text.
struct RecipientField: NSViewRepresentable {
    let label: String
    @AppStorage(ComposePreferences.fullAddressesKey) private var showsFullAddresses = false
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = true
    @Binding var addresses: [EmailAddress]
    /// Set to move the cursor here. The field clears it once it has the cursor.
    @Binding var requestsFocus: Bool
    var isEditable: Bool
    let accountID: String?
    let avatarContext: AddressAvatarContext
    var onFocusChange: @MainActor (Bool) -> Void = { _ in }
    var directorySuggestions: @MainActor (String) async -> [EmailAddress] = { _ in [] }
    var groupSuggestions: @MainActor (String) async -> [ContactGroupSuggestion] = { _ in [] }
    var expandGroup: @MainActor (ContactGroupSuggestion) async -> [EmailAddress]? = { _ in nil }
    /// Keeps an address out of future suggestions; from a token's menu.
    var blockSuggestion: @MainActor (EmailAddress) async -> Void = { _ in }
    let suggestions: @MainActor (String) async -> [EmailAddress]

    init(label: String, addresses: Binding<[EmailAddress]>, requestsFocus: Binding<Bool>, isEditable: Bool,
         accountID: String? = nil, avatarContext: AddressAvatarContext = .empty,
         onFocusChange: @escaping @MainActor (Bool) -> Void = { _ in },
         directorySuggestions: @escaping @MainActor (String) async -> [EmailAddress] = { _ in [] },
         groupSuggestions: @escaping @MainActor (String) async -> [ContactGroupSuggestion] = { _ in [] },
         expandGroup: @escaping @MainActor (ContactGroupSuggestion) async -> [EmailAddress]? = { _ in nil },
         blockSuggestion: @escaping @MainActor (EmailAddress) async -> Void = { _ in },
         suggestions: @escaping @MainActor (String) async -> [EmailAddress]) {
        self.label = label; self._addresses = addresses; self._requestsFocus = requestsFocus; self.isEditable = isEditable
        self.accountID = accountID; self.avatarContext = avatarContext
        self.onFocusChange = onFocusChange; self.directorySuggestions = directorySuggestions
        self.groupSuggestions = groupSuggestions; self.expandGroup = expandGroup
        self.blockSuggestion = blockSuggestion; self.suggestions = suggestions
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// The first line's baseline, measured once on a field nobody is typing in.
    /// SwiftUI asks for a baseline during layout, and asking a field that is
    /// being edited turns its typed text into tokens, which changes its layout
    /// and asks again without end. Callers align on this value instead.
    /// `sizeThatFits` avoids the edited field for a similar reason.
    static let firstBaseline: CGFloat = {
        let field = makeField()
        field.sizeToFit()
        return field.firstBaselineOffsetFromTop
    }()

    static func makeField() -> RecipientTokenField {
        let field = RecipientTokenField()
        field.isBordered = false
        field.drawsBackground = false
        // ComposeView outlines the whole row, including its label and padding.
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",;")
        field.completionDelay = 0.1
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = Self.makeField()
        field.delegate = context.coordinator
        field.focusChanged = { [weak coordinator = context.coordinator] in
            coordinator?.reportFocus()
        }
        field.didLeaveWindow = { [weak coordinator = context.coordinator] in coordinator?.cancelRequests() }
        field.setAccessibilityLabel(label)
        context.coordinator.field = field
        context.coordinator.configureAvatars()
        context.coordinator.show(addresses)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        field.isEditable = isEditable
        context.coordinator.configureAvatars()
        if addresses != context.coordinator.shownAddresses || showsFullAddresses != context.coordinator.showsFullAddresses {
            context.coordinator.show(addresses)
        }
        if requestsFocus, isEditable {
            // Changing focus or the binding during a view update isn't allowed.
            Task { @MainActor in
                // A click in the current row's padding must not select its text again.
                if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
                requestsFocus = false
            }
        }
    }

    static func dismantleNSView(_ field: NSTokenField, coordinator: Coordinator) {
        coordinator.cancelRequests()
        coordinator.field = nil
    }

    /// Measures a copy of the field. Measuring a field that is being edited
    /// lays out its field editor, which makes SwiftUI measure again, until
    /// AppKit stops the loop by raising an exception.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTokenField, context: Context) -> CGSize? {
        let size = context.coordinator.measure(width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    /// The text that edits an address, and that copying a token puts on the pasteboard.
    static func editingString(_ address: EmailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.address }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" <\(address.address)>"
    }

    /// An address as text the field turns back into one token. The name
    /// leaves out commas and semicolons, which would end the token.
    static func tokenText(_ address: EmailAddress) -> String {
        let name = address.name?.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ";", with: "")
        return name.map { "\($0) <\(address.address)>" } ?? address.address
    }

    /// The address in one token. Tokens hold objects, not values.
    final class Token: NSObject {
        let address: EmailAddress

        init(_ address: EmailAddress) {
            self.address = address
        }
    }

    final class GroupToken: NSObject {
        let group: ContactGroupSuggestion
        init(_ group: ContactGroupSuggestion) { self.group = group }
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: RecipientField
        weak var field: NSTokenField?
        /// What the field shows, so updates that come back from the binding leave it alone.
        private(set) var shownAddresses: [EmailAddress] = []
        private(set) var showsFullAddresses = false
        private var loadedQuery: String?
        private var loaded: [EmailAddress] = []
        private var loadedGroups: [ContactGroupSuggestion] = []
        private var loadedDirectory: [EmailAddress] = []
        private var groupCompletions: [String: ContactGroupSuggestion] = [:]
        private var groupTasks: [String: Task<Void, Never>] = [:]
        /// Completion strings and the addresses they stand for. A name's commas
        /// are left out of its completion string, since a comma ends a token.
        private var completions: [String: EmailAddress] = [:]
        /// Text that Edit made from a token, and the address it stands for.
        private var editedAddresses: [String: EmailAddress] = [:]
        private var loadTask: Task<Void, Never>?
        private var queryGeneration = 0
        /// Never on screen or edited, so SwiftUI can measure it at any time.
        private let sizingField = RecipientField.makeField()
        private var sizedAddresses: [EmailAddress]?
        private var sizedFullAddresses = false
        private var reportedFocus = false
        private let avatars = RecipientAvatarController()
        private var requestedQuery: String?
        private var dismissedQuery: String?

        init(_ parent: RecipientField) {
            self.parent = parent
            super.init()
            sizingField.delegate = self
            avatars.afterAcceptance = { [weak self] in self?.publish() }
        }

        func configureAvatars() {
            avatars.configure(field: field as? RecipientTokenField, accountID: parent.accountID,
                              context: parent.avatarContext, showsLogos: parent.showsLogos)
        }

        func show(_ addresses: [EmailAddress]) {
            shownAddresses = addresses
            showsFullAddresses = parent.showsFullAddresses
            field?.objectValue = addresses.map(Token.init)
            avatars.updateChips(addresses)
        }

        func cancelRequests() {
            loadTask?.cancel()
            requestedQuery = nil
            queryGeneration += 1
            for task in groupTasks.values { task.cancel() }
            groupTasks = [:]
            avatars.stop()
        }

        /// AppKit can change focus during a SwiftUI update. Read the current
        /// responder after that update so queued notifications cannot restore stale focus.
        func reportFocus() {
            Task { @MainActor [weak self] in
                guard let self, let field else { return }
                let responder = field.window?.firstResponder
                let ownsEditor = field.currentEditor().map { responder === $0 } ?? false
                let isFocused = responder === field || ownsEditor
                guard isFocused != reportedFocus else { return }
                reportedFocus = isFocused
                if !isFocused { avatars.hideSuggestions() }
                (field as? RecipientTokenField)?.refreshAvatars()
                parent.onFocusChange(isFocused)
            }
        }

        /// The size of the shown addresses, wrapped at `width`. A width that
        /// isn't positive and finite gives a single line.
        func measure(width: CGFloat) -> CGSize {
            if sizedAddresses != shownAddresses || sizedFullAddresses != parent.showsFullAddresses {
                sizedAddresses = shownAddresses
                sizedFullAddresses = parent.showsFullAddresses
                sizingField.objectValue = shownAddresses.map(Token.init)
            }
            let wrapWidth = width.isFinite && width > 0 ? width : .greatestFiniteMagnitude
            let bounds = NSRect(x: 0, y: 0, width: wrapWidth, height: .greatestFiniteMagnitude)
            let size = sizingField.cell?.cellSize(forBounds: bounds) ?? .zero
            return CGSize(width: ceil(size.width), height: ceil(size.height))
        }

        // MARK: NSTokenFieldDelegate

        func controlTextDidBeginEditing(_ notification: Notification) {
            reportFocus()
        }

        func controlTextDidChange(_ notification: Notification) {
            if let editor = field?.currentEditor() as? NSTextView, editor.hasMarkedText() {
                avatars.hideSuggestions()
                return
            }
            publish()
            dismissedQuery = nil
            avatars.hideSuggestions()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            publish()
            avatars.hideSuggestions()
            reportFocus()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let handled = avatars.handleCommand(commandSelector, editor: textView)
            if handled, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                dismissedQuery = loadedQuery
                loadTask?.cancel()
                queryGeneration += 1
            }
            return handled
        }

        func tokenField(
            _ tokenField: NSTokenField,
            completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            let query = substring.trimmingCharacters(in: .whitespaces).lowercased()
            if query == dismissedQuery { return [] }
            guard !query.isEmpty else {
                loadTask?.cancel()
                queryGeneration += 1
                loadedQuery = nil
                loaded = []
                loadedGroups = []; loadedDirectory = []; groupCompletions = [:]
                completions = [:]
                requestedQuery = nil
                avatars.hideSuggestions()
                return []
            }
            if query == loadedQuery {
                // Return picks the first match for a name, but never replaces an address being typed.
                selectedIndex?.pointee = query.contains("@") || (loaded.isEmpty && loadedGroups.isEmpty && loadedDirectory.isEmpty) ? -1 : 0
                let strings = loaded.map(completionString) + loadedGroups.map(groupCompletionString) + loadedDirectory.map(completionString)
                presentSuggestions(query: query, tokenField: tokenField)
                return tokenField is RecipientTokenField ? [] : strings
            }
            if query == requestedQuery { return [] }
            loadTask?.cancel()
            // A return to the previous text must start a new request rather
            // than reuse its rows while a different query is still in flight.
            loadedQuery = nil
            loaded = []
            loadedGroups = []; loadedDirectory = []; groupCompletions = [:]
            completions = [:]
            requestedQuery = query
            avatars.hideSuggestions()
            queryGeneration += 1
            let generation = queryGeneration
            let suggestions = parent.suggestions
            let directory = parent.directorySuggestions
            let groups = parent.groupSuggestions
            loadTask = Task { [weak self, weak tokenField] in
                let results = await suggestions(query)
                let groupResults = await groups(query)
                guard let self, !Task.isCancelled, queryGeneration == generation else { return }
                loadedQuery = query
                requestedQuery = nil
                loaded = results
                loadedGroups = groupResults
                completions = [:]
                if let tokenField { presentSuggestions(query: query, tokenField: tokenField) }
                guard query.count >= 2 else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                let remote = await directory(query)
                guard !Task.isCancelled, queryGeneration == generation else { return }
                var seen = Set(loaded.map(\.normalized))
                let additions = remote.filter { seen.insert($0.normalized).inserted }
                guard !additions.isEmpty else { return }
                loadedDirectory = additions
                if let tokenField { presentSuggestions(query: query, tokenField: tokenField) }
            }
            return []
        }

        func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
            let text = editingString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let group = groupCompletions[text] { return GroupToken(group) }
            if let address = completions[text] ?? editedAddresses[text] { return Token(address) }
            return Token(EmailAddress.parseList(text).first ?? EmailAddress(address: text))
        }

        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject object: Any) -> String? {
            if let group = object as? GroupToken { return group.group.name }
            guard let token = object as? Token else { return object as? String }
            let display: String
            if parent.showsFullAddresses { display = token.address.displayString }
            else if let name = token.address.name, !name.isEmpty { display = name }
            else { display = token.address.address }
            return (tokenField is RecipientTokenField && token.address.isValid ? RecipientTokenField.avatarPrefix : "") + display
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject object: Any) -> String? {
            if let group = object as? GroupToken { return group.group.name }
            return (object as? Token).map { RecipientField.editingString($0.address) } ?? object as? String
        }

        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            for token in tokens.compactMap({ $0 as? GroupToken }) {
                let group = token.group
                guard groupTasks[group.id] == nil else { continue }
                let expansion = parent.expandGroup
                groupTasks[group.id] = Task { [weak self] in
                    let addresses = await expansion(group)
                    guard let self else { return }
                    defer { groupTasks[group.id] = nil }
                    guard !Task.isCancelled, let addresses, field != nil, parent.isEditable else { return }
                    var recipients = parent.addresses
                    var seen = Set(recipients.map(\.normalized))
                    recipients += addresses.filter { seen.insert($0.normalized).inserted }
                    parent.addresses = recipients
                    show(recipients)
                }
            }
            return tokens.filter { !($0 is GroupToken) }
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

        // MARK: Token menu

        func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject object: Any) -> Bool {
            object is Token
        }

        func tokenField(_ tokenField: NSTokenField, menuForRepresentedObject object: Any) -> NSMenu? {
            guard let token = object as? Token else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            let items: [(title: String, action: Selector, isEnabled: Bool)] = [
                ("Copy Address", #selector(copyAddress(_:)), true),
                ("Edit", #selector(editToken(_:)), parent.isEditable),
                ("Remove", #selector(removeToken(_:)), parent.isEditable),
            ]
            for entry in items {
                menu.addItem(menuItem(entry.title, action: entry.action, token: token, isEnabled: entry.isEnabled))
            }
            menu.addItem(.separator())
            menu.addItem(menuItem("Hide from Suggestions", action: #selector(blockToken(_:)), token: token,
                                  isEnabled: token.address.isValid))
            return menu
        }

        private func menuItem(_ title: String, action: Selector, token: Token, isEnabled: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = token
            item.isEnabled = isEnabled
            return item
        }

        /// The token's position among the field's objects. The field hands the
        /// menu the object it holds; the address is a fallback.
        private func index(of token: Token, in objects: [Any]) -> Int? {
            objects.firstIndex { ($0 as? Token) === token } ?? objects.firstIndex { ($0 as? Token)?.address == token.address }
        }

        /// The token's character in the field editor, which holds each token as one attachment.
        private static func range(of token: Token, in editor: NSTextView) -> NSRange? {
            guard let storage = editor.textStorage else { return nil }
            var found: NSRange?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard let cell = (value as? NSTextAttachment)?.attachmentCell as? NSCell,
                      (cell.representedObject as? Token) === token else { return }
                found = range
                stop.pointee = true
            }
            return found
        }

        @objc private func copyAddress(_ item: NSMenuItem) {
            guard let token = item.representedObject as? Token else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RecipientField.editingString(token.address), forType: .string)
        }

        /// Turns the token back into selected text, so typing replaces it.
        /// Until it changes, the text stands for the original address, whose
        /// name may hold the commas the text leaves out.
        @objc private func editToken(_ item: NSMenuItem) {
            guard parent.isEditable, let field, let token = item.representedObject as? Token else { return }
            if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
            guard let editor = field.currentEditor() as? NSTextView, let range = Self.range(of: token, in: editor) else { return }
            let text = RecipientField.tokenText(token.address)
            editedAddresses[text] = token.address
            editor.insertText(text, replacementRange: range)
            editor.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
        }

        @objc private func removeToken(_ item: NSMenuItem) {
            guard parent.isEditable, let field, let token = item.representedObject as? Token,
                  var objects = field.objectValue as? [Any], let index = index(of: token, in: objects) else { return }
            objects.remove(at: index)
            field.objectValue = objects
            publish()
        }

        @objc private func blockToken(_ item: NSMenuItem) {
            guard let token = item.representedObject as? Token else { return }
            let block = parent.blockSuggestion
            Task { await block(token.address) }
        }

        // MARK: Private

        private func presentSuggestions(query: String, tokenField: NSTokenField) {
            guard tokenField is RecipientTokenField else { return }
            let generation = queryGeneration
            let addressRows = { (addresses: [EmailAddress]) in
                addresses.map { address in
                    let title = address.name ?? address.address
                    return RecipientSuggestion(completion: self.completionString(address), title: title,
                                               subtitle: title.caseInsensitiveCompare(address.address) == .orderedSame ? "" : address.address,
                                               address: address)
                }
            }
            let groups = loadedGroups.map { group in
                RecipientSuggestion(completion: groupCompletionString(group), title: group.name,
                                    subtitle: "\(group.memberCount) members" + (group.isComplete ? "" : " · list incomplete"), address: nil)
            }
            avatars.present(addressRows(loaded) + groups + addressRows(loadedDirectory), for: tokenField, query: query,
                            isCurrent: { [weak self, weak tokenField] in
                                guard let self, let tokenField else { return false }
                                return field === tokenField && queryGeneration == generation && loadedQuery == query
                            }, selectFirst: !query.contains("@"))
        }

        private func completionString(_ address: EmailAddress) -> String {
            let string = RecipientField.tokenText(address)
            completions[string] = address
            return string
        }

        private func groupCompletionString(_ group: ContactGroupSuggestion) -> String {
            let name = group.name.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ";", with: "")
            let coverage = group.isComplete ? "" : " · list incomplete"
            let base = "\(name) (group · \(group.memberCount)\(coverage))"
            var text = base
            var number = 2
            while let existing = groupCompletions[text], existing.id != group.id { text = "\(base) (\(number))"; number += 1 }
            groupCompletions[text] = group
            return text
        }

        /// Tokens, then any text still being typed.
        private func publish() {
            guard let field else { return }
            let objects = field.objectValue as? [Any] ?? []
            avatars.updateChips(objects.compactMap { ($0 as? Token)?.address })
            let addresses = objects.flatMap { object -> [EmailAddress] in
                if let token = object as? Token { return [token.address] }
                guard let text = (object as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    return []
                }
                if let address = editedAddresses[text] { return [address] }
                let parsed = EmailAddress.parseList(text)
                return parsed.isEmpty ? [EmailAddress(address: text)] : parsed
            }
            shownAddresses = addresses
            if parent.addresses != addresses { parent.addresses = addresses }
        }
    }
}
