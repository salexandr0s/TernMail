import AppKit
import MailStore
import SwiftUI

/// Both layouts use the same page and selection. Only the cards need custom
/// arrow-key handling; List supplies native range and command selection.
struct AttachmentLibraryCollection: View {
    @Bindable var model: AttachmentLibraryModel
    let viewMode: AttachmentLibraryViewMode
    let availableWidth: CGFloat
    @State private var anchorID: String?
    @State private var currentID: String?
    /// Shift and Command as last pressed, for clicks. Keyboard and VoiceOver
    /// selection pass their own modifiers, so a stale event can't widen it.
    @State private var heldModifiers: EventModifiers = []
    @FocusState private var gridFocused: Bool
    @FocusState private var listFocused: Bool
    @Namespace private var dragNamespace

    private var columns: Int {
        max(1, Int((availableWidth - Tokens.Space.s5 * 2 + Tokens.Space.s4) /
            (Tokens.Layout.attachmentWidth + Tokens.Space.s4)))
    }

    var body: some View {
        Group {
            if viewMode == .grid { cards }
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
                else { await model.openFiles(model.selectedItems(with: item)) }
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
            if viewMode == .list, !selection.isEmpty { listFocused = true }
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: Tokens.Space.s3) {
            Text("File and source email").frame(maxWidth: .infinity, alignment: .leading)
            Text("Sender").frame(width: Tokens.Layout.sidebarMinWidth, alignment: .leading)
            Text("Received").frame(width: Tokens.Space.s16 * 2, alignment: .trailing)
            Color.clear.frame(width: Tokens.Control.iconButton, height: 0)
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.top, Tokens.Space.s1).padding(.bottom, Tokens.Space.s2)
        .accessibilityHidden(true)
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.items) { item in listRow(item) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .attachmentDragContainer(model, in: dragNamespace)
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = model.items.first(where: { ids.contains($0.id) }) {
                AttachmentItemMenu(item: item, model: model)
            }
        } primaryAction: { ids in
            let files = model.items.filter { ids.contains($0.id) }
            Task { await model.openFiles(files) }
        }
        .focused($listFocused)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Attachments list")
        .accessibilityHint("Select a file and press Space for Quick Look or Return to open it. Command-click or Shift-click selects several files.")
    }

    private func listRow(_ item: AttachmentLibraryItem) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            AttachmentLibraryRow(item: item, accountName: model.accountName(item),
                accounts: model.availableAccounts, compact: availableWidth < Tokens.Layout.readableWidth)
                .equatable()
            AttachmentLibraryItemActions(item: item, model: model)
                .padding(.top, Tokens.Space.s3)
        }
        .tag(item.id)
        .draggable(containerItemID: item.id, containerNamespace: dragNamespace)
        .attachmentAccessibilityActions(item, model: model) { Task { await model.openFile(item) } }
    }

    private var cards: some View {
        ScrollViewReader { reader in
            cardGrid
                .focusable().focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    // Shift-arrow extends the range; Command-arrow doesn't toggle cards.
                    move(press.key, modifiers: press.modifiers.intersection(.shift), reader: reader)
                    return .handled
                }
                .onModifierKeysChanged(mask: [.shift, .command]) { _, new in heldModifiers = new }
                .accessibilityLabel("Attachment cards")
                .accessibilityHint("Use arrow keys to select, Space for Quick Look, Return to open. Command-click or Shift-click selects several files.")
        }
    }

    private var cardGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Layout.attachmentWidth), spacing: Tokens.Space.s4)],
                      spacing: Tokens.Space.s4) {
                ForEach(model.items) { item in
                    AttachmentCardCell(item: item, model: model, onClick: { select(item, modifiers: heldModifiers) },
                                       onActivate: { select(item, modifiers: []) }, onOpen: { open(item) })
                        .draggable(containerItemID: item.id, containerNamespace: dragNamespace)
                        .id(item.id)
                }
            }
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.top, Tokens.Space.s1).padding(.bottom, Tokens.Space.s5)
            .background(PerformanceScrollSurfaceMarker(name: "attachments", isActive: true))
        }
        .attachmentDragContainer(model, in: dragNamespace)
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

    /// Double-clicking a selected file opens the whole selection, as in Finder.
    private func open(_ item: AttachmentLibraryItem) {
        if !model.selection.contains(item.id) { select(item, modifiers: []) }
        let files = model.selectedItems(with: item)
        Task { await model.openFiles(files) }
    }

    private func moveSelection(by delta: Int, modifiers: EventModifiers) {
        guard !model.items.isEmpty else { return }
        let old = model.items.firstIndex { $0.id == currentID }
            ?? model.items.firstIndex { model.selection.contains($0.id) }
        let index = old.map { min(model.items.count - 1, max(0, $0 + delta)) } ?? 0
        select(model.items[index], modifiers: modifiers)
    }
}

private struct AttachmentCardCell: View {
    let item: AttachmentLibraryItem
    let model: AttachmentLibraryModel
    let onClick: () -> Void
    /// The accessibility default action, which never extends a selection.
    let onActivate: () -> Void
    let onOpen: () -> Void

    var body: some View {
        AttachmentLibraryCard(item: item, accountName: model.accountName(item),
            accounts: model.availableAccounts, selected: model.selection.contains(item.id))
            .equatable()
            .onTapGesture(count: 2, perform: onOpen)
            .onTapGesture(perform: onClick)
            .contextMenu { AttachmentItemMenu(item: item, model: model) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onActivate() }
            .attachmentAccessibilityActions(item, model: model, open: onOpen)
            .overlay(alignment: .topTrailing) {
                AttachmentLibraryItemActions(item: item, model: model)
                    .padding(Tokens.Space.s4)
            }
    }
}

/// The same file commands as the native context menu, available without a right-click.
private struct AttachmentLibraryItemActions: View {
    let item: AttachmentLibraryItem
    let model: AttachmentLibraryModel

    var body: some View {
        Menu {
            AttachmentItemMenu(item: item, model: model)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isWorking)
        .help("Actions for \(item.filename)")
        .accessibilityLabel("Actions for \(item.filename)")
        .accessibilityIdentifier("attachments.item.actions.\(item.id)")
    }
}

extension AttachmentRecord {
    /// The library item this file belongs to, matching `AttachmentLibraryItem.id`,
    /// so a drag container keyed by library item can name each file.
    var libraryID: AttachmentLibraryItem.ID {
        [accountID, messageID, partID].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

private extension View {
    /// The item menu's commands for VoiceOver. Share stays in the context
    /// menu, which VoiceOver also opens, because its picker needs a place
    /// on screen.
    func attachmentAccessibilityActions(
        _ item: AttachmentLibraryItem, model: AttachmentLibraryModel, open: @escaping () -> Void
    ) -> some View {
        accessibilityActions {
            Button("Open", action: open)
            Button("Quick Look") { Task { await model.preview(item) } }
            Button("Save") { Task { await model.save(item) } }
            if let saved = model.savedFile(for: item) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
            }
            Button("Open Conversation in New Window") { Task { await model.openSource(item) } }
        }
    }

    /// Dragging a selected file carries the whole selection. Each file
    /// downloads only when the receiver asks for it.
    func attachmentDragContainer(_ model: AttachmentLibraryModel, in namespace: Namespace.ID) -> some View {
        dragContainer(for: AttachmentFileItem.self, itemID: \.attachment.libraryID, in: namespace) { (ids: [AttachmentLibraryItem.ID]) in
            let ids = Set(ids)
            return model.items.filter { ids.contains($0.id) }
                .map { AttachmentFileItem(attachment: $0.attachment, mailbox: model.mailbox) }
        }
        .dragContainerSelection(Array(model.selection), containerNamespace: namespace)
    }
}
