import MailStore
import SwiftUI

/// Both layouts use the same page and selection. Only the cards need custom
/// arrow-key handling; List supplies native range and command selection.
struct AttachmentLibraryCollection: View {
    @Bindable var model: AttachmentLibraryModel
    let viewMode: String
    let availableWidth: CGFloat
    let onOpenSource: () -> Void
    @State private var anchorID: String?
    @State private var currentID: String?
    /// Shift and Command as last pressed, for clicks. Keyboard and VoiceOver
    /// selection pass their own modifiers, so a stale event can't widen it.
    @State private var heldModifiers: EventModifiers = []
    @FocusState private var gridFocused: Bool
    @FocusState private var listFocused: Bool

    private var columns: Int {
        max(1, Int((availableWidth - Tokens.Space.s5 * 2 + Tokens.Space.s4) /
            (Tokens.Layout.attachmentWidth + Tokens.Space.s4)))
    }

    var body: some View {
        Group {
            if viewMode == "grid" { cards }
            else {
                VStack(spacing: 0) {
                    if availableWidth >= Tokens.Layout.readableWidth { columnHeadings }
                    list
                }
            }
        }
        .onKeyPress(keys: [.space, .return]) { press in
            guard let item = model.items.first(where: { model.selection.contains($0.id) }), !model.isWorking else { return .ignored }
            Task {
                if press.key == .space { await model.preview(item) }
                else { await model.openFile(item) }
            }
            return .handled
        }
        .onKeyPress("a", phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.selection = Set(model.items.map(\.id))
            return .handled
        }
        .onKeyPress(.escape) {
            model.selection.removeAll()
            return .handled
        }
        .onChange(of: model.pageOffset) { _, _ in anchorID = nil; currentID = nil }
        .onChange(of: viewMode) { _, _ in
            currentID = model.items.first { model.selection.contains($0.id) }?.id
            anchorID = currentID
        }
        .onChange(of: model.selection) { _, selection in
            if viewMode == "list", !selection.isEmpty { listFocused = true }
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: Tokens.Space.s3) {
            Text("File").frame(maxWidth: .infinity, alignment: .leading)
            Text("From").frame(width: Tokens.Layout.sidebarMinWidth, alignment: .leading)
            Text("Received").frame(width: Tokens.Space.s16 * 2, alignment: .trailing)
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.top, Tokens.Space.s1).padding(.bottom, Tokens.Space.s2)
        .accessibilityHidden(true)
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                AttachmentLibraryRow(item: item, accountName: model.accountName(item),
                    accounts: model.availableAccounts, compact: availableWidth < Tokens.Layout.readableWidth)
                    .tag(item.id)
                    .accessibilityAction(named: "Preview") { Task { await model.preview(item) } }
                    .accessibilityAction(named: "Save") { Task { await model.save(item) } }
                    .accessibilityAction(named: "Show Email") { openSource(item) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = model.items.first(where: { ids.contains($0.id) }) {
                AttachmentItemMenu(item: item, model: model, onOpenSource: onOpenSource)
            }
        } primaryAction: { ids in
            guard let item = model.items.first(where: { ids.contains($0.id) }) else { return }
            Task { await model.preview(item) }
        }
        .focused($listFocused)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Attachments list")
        .accessibilityHint("Select a file and press Space to preview or Return to open. Command-click or Shift-click selects several files.")
    }

    private var cards: some View {
        ScrollViewReader { reader in
            cardGrid
                .focusable().focused($gridFocused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    // Shift-arrow extends the range; Command-arrow doesn't toggle cards.
                    move(press.key, modifiers: press.modifiers.intersection(.shift), reader: reader)
                    return .handled
                }
                .onModifierKeysChanged(mask: [.shift, .command]) { _, new in heldModifiers = new }
                .accessibilityLabel("Attachment cards")
                .accessibilityHint("Use arrow keys to select, Space to preview, Return to open. Command-click or Shift-click selects several files.")
        }
    }

    private var cardGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Layout.attachmentWidth), spacing: Tokens.Space.s4)],
                      spacing: Tokens.Space.s4) {
                ForEach(model.items) { item in
                    AttachmentCardCell(item: item, model: model, onClick: { select(item, modifiers: heldModifiers) },
                                       onActivate: { select(item, modifiers: []) }, onOpenSource: onOpenSource)
                        .id(item.id)
                }
            }
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.top, Tokens.Space.s1).padding(.bottom, Tokens.Space.s5)
        }
    }

    private func move(_ key: KeyEquivalent, modifiers: EventModifiers, reader: ScrollViewProxy) {
        let delta: Int
        switch key {
        case .leftArrow: delta = -1
        case .rightArrow: delta = 1
        case .upArrow: delta = -columns
        case .downArrow: delta = columns
        default: return
        }
        moveSelection(by: delta, modifiers: modifiers)
        if let currentID { reader.scrollTo(currentID) }
    }

    private func select(_ item: AttachmentLibraryItem, modifiers: EventModifiers) {
        gridFocused = true
        if modifiers.contains(.shift), let anchorID,
           let start = model.items.firstIndex(where: { $0.id == anchorID }),
           let end = model.items.firstIndex(where: { $0.id == item.id }) {
            model.selection = Set(model.items[min(start, end)...max(start, end)].map(\.id))
        } else if modifiers.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) }
            else { model.selection.insert(item.id) }
            anchorID = item.id
        } else {
            model.selection = [item.id]
            anchorID = item.id
        }
        currentID = item.id
    }

    private func moveSelection(by delta: Int, modifiers: EventModifiers) {
        guard !model.items.isEmpty else { return }
        let old = model.items.firstIndex { $0.id == currentID }
            ?? model.items.firstIndex { model.selection.contains($0.id) }
        let index = old.map { min(model.items.count - 1, max(0, $0 + delta)) } ?? 0
        select(model.items[index], modifiers: modifiers)
    }

    private func openSource(_ item: AttachmentLibraryItem) {
        Task { if await model.openSource(item) { onOpenSource() } }
    }
}

private struct AttachmentCardCell: View {
    let item: AttachmentLibraryItem
    let model: AttachmentLibraryModel
    let onClick: () -> Void
    /// The accessibility default action, which never extends a selection.
    let onActivate: () -> Void
    let onOpenSource: () -> Void

    var body: some View {
        AttachmentLibraryCard(item: item, accountName: model.accountName(item),
            accounts: model.availableAccounts, selected: model.selection.contains(item.id))
            .onTapGesture(count: 2) { Task { await model.preview(item) } }
            .onTapGesture(perform: onClick)
            .contextMenu { AttachmentItemMenu(item: item, model: model, onOpenSource: onOpenSource) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onActivate() }
            .accessibilityAction(named: "Preview") { Task { await model.preview(item) } }
            .accessibilityAction(named: "Save") { Task { await model.save(item) } }
            .accessibilityAction(named: "Show Email") {
                Task { if await model.openSource(item) { onOpenSource() } }
            }
    }
}
