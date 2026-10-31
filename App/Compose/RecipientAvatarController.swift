import AppKit
import MessageContent

@MainActor
final class RecipientAvatarController {
    private weak var field: RecipientTokenField?
    private var accountID: String?
    private var context = AddressAvatarContext.empty
    private var showsLogos = true
    private var chipAddresses: [EmailAddress] = []
    private var models: [String: AddressAvatarModel] = [:]
    private var panel: RecipientSuggestionsPanel?
    private weak var completionEditor: NSTextView?
    private var replacementRange = NSRange(location: NSNotFound, length: 0)
    private var replacementText = ""
    private var replacementSelection = NSRange(location: NSNotFound, length: 0)
    private var isCurrentQuery: (() -> Bool)?
    var afterAcceptance: (() -> Void)?

    func configure(field: RecipientTokenField?, accountID: String?, context: AddressAvatarContext, showsLogos: Bool) {
        self.field = field
        self.accountID = accountID
        self.context = context
        self.showsLogos = showsLogos
        field?.avatarImage = { [weak self] in self?.models[$0.normalized]?.image }
        refreshModels()
    }

    func updateChips(_ addresses: [EmailAddress]) {
        chipAddresses = addresses.filter(\.isValid)
        field?.avatarAddresses = chipAddresses
        refreshModels()
    }

    func stop() {
        hideSuggestions()
        models.values.forEach { $0.stop() }
        models = [:]
        field?.avatarImage = nil
    }

    func hideSuggestions() {
        panel?.close()
        completionEditor = nil
        isCurrentQuery = nil
        refreshModels()
    }

    func present(_ rows: [RecipientSuggestion], for field: NSTokenField, query: String, isCurrent: @escaping () -> Bool, selectFirst: Bool) {
        guard field is RecipientTokenField, let editor = field.currentEditor() as? NSTextView,
              !editor.hasMarkedText(), isCurrent() else { hideSuggestions(); return }
        let range = editor.rangeForUserCompletion
        let text = editor.string as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length, !rows.isEmpty else { hideSuggestions(); return }
        guard text.substring(with: range).trimmingCharacters(in: .whitespaces).lowercased() == query else { hideSuggestions(); return }
        completionEditor = editor
        replacementRange = range
        replacementText = text.substring(with: range)
        replacementSelection = editor.selectedRange()
        isCurrentQuery = isCurrent
        if panel == nil {
            let created = RecipientSuggestionsPanel()
            created.image = { [weak self] in self?.models[$0.normalized]?.image }
            created.onChoose = { [weak self] in self?.accept($0) }
            created.onDismiss = { [weak self] in self?.hideSuggestions() }
            panel = created
        }
        panel?.show(rows, for: field, selectFirst: selectFirst)
        refreshModels()
    }

    func handleCommand(_ command: Selector, editor: NSTextView) -> Bool {
        guard !editor.hasMarkedText(), let panel, panel.isVisible else { return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            panel.moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            panel.moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            guard let selected = panel.selected else { hideSuggestions(); return false }
            return accept(selected)
        case #selector(NSResponder.cancelOperation(_:)):
            hideSuggestions(); return true
        default: return false
        }
    }

    @discardableResult
    private func accept(_ suggestion: RecipientSuggestion) -> Bool {
        guard let field, let editor = completionEditor, field.currentEditor() === editor,
              !editor.hasMarkedText(), isCurrentQuery?() == true,
              editor.selectedRange() == replacementSelection,
              editor.rangeForUserCompletion == replacementRange else { hideSuggestions(); return false }
        let text = editor.string as NSString
        guard NSMaxRange(replacementRange) <= text.length, text.substring(with: replacementRange) == replacementText else {
            hideSuggestions(); return false
        }
        let range = replacementRange
        hideSuggestions()
        editor.insertCompletion(suggestion.completion, forPartialWordRange: range, movement: NSReturnTextMovement, isFinal: true)
        afterAcceptance?()
        field.refreshAvatars()
        return true
    }

    private func refreshModels() {
        guard let field else { return }
        let addresses = chipAddresses + (panel?.rows.compactMap(\.address) ?? [])
        var active: [String: EmailAddress] = [:]
        for address in addresses where address.isValid { active[address.normalized] = address }
        for key in Array(models.keys) where active[key] == nil { models.removeValue(forKey: key)?.stop() }
        for (key, address) in active {
            let model: AddressAvatarModel
            if let existing = models[key] { model = existing }
            else {
                model = AddressAvatarModel()
                model.onChange = { [weak self] in self?.redraw() }
                models[key] = model
            }
            model.configure(address: address.address, accountID: accountID, context: context, showsLogos: showsLogos)
        }
        field.refreshAvatars()
        panel?.refreshAvatars()
    }

    private func redraw() {
        field?.refreshAvatars()
        panel?.refreshAvatars()
    }
}
