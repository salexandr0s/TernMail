import SwiftUI

/// A label as the pickers show it.
struct LabelChoice: Identifiable, Equatable {
    let id: String
    let name: String
    var backgroundColor: String?
    var systemImage = "tag"
}

/// What Edit Labels shows for each label across the selected conversations,
/// and what applying it changes.
struct LabelSelection: Equatable {
    enum State: Equatable {
        case on, off, mixed
    }

    struct Change: Equatable {
        var add: Set<String> = []
        var remove: Set<String> = []

        var isEmpty: Bool { add.isEmpty && remove.isEmpty }
    }

    private let initial: [String: State]
    private var current: [String: State]

    /// - Parameter applied: Each selected conversation's label IDs.
    init(applied: [Set<String>]) {
        var counts: [String: Int] = [:]
        for labels in applied {
            for id in labels { counts[id, default: 0] += 1 }
        }
        initial = counts.mapValues { $0 == applied.count ? .on : .mixed }
        current = initial
    }

    func state(of id: String) -> State {
        current[id] ?? .off
    }

    /// On and off alternate. A label that started mixed comes back to mixed
    /// after off, which leaves every conversation as it was.
    mutating func toggle(_ id: String) {
        current[id] = switch state(of: id) {
        case .off: initial[id] == .mixed ? .mixed : .on
        case .mixed: .on
        case .on: .off
        }
    }

    var change: Change {
        var change = Change()
        for (id, state) in current where state != (initial[id] ?? .off) {
            switch state {
            case .on: change.add.insert(id)
            case .off: change.remove.insert(id)
            case .mixed: break
            }
        }
        return change
    }
}

/// Edit Labels: a filterable checklist for the selected conversations.
struct EditLabelsView: View {
    let labels: [LabelChoice]
    let onApply: (LabelSelection.Change) -> Void
    /// Gets the new label's name and the boxes changed so far.
    let onCreateLabel: (String, LabelSelection.Change) -> Void

    @State private var selection: LabelSelection
    @Environment(\.dismiss) private var dismiss

    init(
        labels: [LabelChoice],
        applied: [Set<String>],
        onApply: @escaping (LabelSelection.Change) -> Void,
        onCreateLabel: @escaping (String, LabelSelection.Change) -> Void
    ) {
        self.labels = labels
        self.onApply = onApply
        self.onCreateLabel = onCreateLabel
        _selection = State(initialValue: LabelSelection(applied: applied))
    }

    var body: some View {
        VStack(spacing: 0) {
            PopupHeader(title: "Edit Labels", systemImage: "tag")
            FilteredLabelList(
                choices: labels,
                mark: { .check(selection.state(of: $0.id)) },
                onPick: { selection.toggle($0.id) },
                onCreate: { onCreateLabel($0, selection.change) }
            )
            PopupFooter {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(selection.change) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(selection.change.isEmpty)
                    .help("Apply (⌘Return)")
            }
        }
        .frame(width: Tokens.Popover.width)
    }
}

/// Move to: picks one of the Inbox and the user labels.
struct MoveToView: View {
    let targets: [LabelChoice]
    let onMove: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PopupHeader(title: "Move to", systemImage: "folder")
            FilteredLabelList(choices: targets, mark: { _ in .none }, onPick: { onMove($0.id) }, onCreate: nil)
        }
        .frame(width: Tokens.Popover.width)
    }
}

/// A row of the filtered list, with its position for the highlight.
private struct LabelPickerItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case label(LabelChoice)
        case create(String)
    }

    let index: Int
    let kind: Kind

    var id: String {
        switch kind {
        case .label(let choice): "label:\(choice.id)"
        case .create: "create"
        }
    }

    /// The labels whose names contain `query`, then Create Label when `query` names none of them.
    static func matching(_ query: String, in choices: [LabelChoice], canCreate: Bool) -> [LabelPickerItem] {
        var kinds: [Kind]
        if query.isEmpty {
            kinds = choices.map(Kind.label)
        } else {
            kinds = choices.filter { $0.name.localizedCaseInsensitiveContains(query) }.map(Kind.label)
            let exists = choices.contains { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            if canCreate, !exists { kinds.append(.create(query)) }
        }
        return kinds.enumerated().map { LabelPickerItem(index: $0.offset, kind: $0.element) }
    }
}

/// A filter field over a list of labels that works like a menu: the arrow
/// keys move the highlight, Return picks it and the pointer highlights too.
private struct FilteredLabelList: View {
    enum Mark {
        case none
        case check(LabelSelection.State)
    }

    let choices: [LabelChoice]
    let mark: (LabelChoice) -> Mark
    let onPick: (LabelChoice) -> Void
    /// Offered when the filter names no label. Nil hides it.
    let onCreate: ((String) -> Void)?

    @State private var filter = ""
    /// The rows for the current filter. They are rebuilt when the filter or the labels
    /// change, so moving the pointer over the list does not filter the labels again.
    @State private var items: [LabelPickerItem]
    @State private var highlighted: Int?
    /// The list's height with no filter. The popover keeps it while a filter narrows the rows.
    @State private var unfilteredHeight: CGFloat?
    @FocusState private var isFilterFocused: Bool

    init(
        choices: [LabelChoice],
        mark: @escaping (LabelChoice) -> Mark,
        onPick: @escaping (LabelChoice) -> Void,
        onCreate: ((String) -> Void)?
    ) {
        self.choices = choices
        self.mark = mark
        self.onPick = onPick
        self.onCreate = onCreate
        _items = State(initialValue: LabelPickerItem.matching("", in: choices, canCreate: onCreate != nil))
    }

    private var trimmedFilter: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                TextField("Filter labels", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFilterFocused)
                    .onSubmit {
                        if let highlighted { pick(at: highlighted) }
                    }
                    .onKeyPress(.downArrow) {
                        move(by: 1, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(by: -1, proxy: proxy)
                        return .handled
                    }
                    .padding(.horizontal, Tokens.Space.s5)
                    .padding(.bottom, Tokens.Space.s3)
                Divider()
                VStack(spacing: 0) {
                    if items.isEmpty {
                        Label("No matching labels", systemImage: "magnifyingglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Tokens.Space.s5)
                    } else {
                        list
                    }
                }
                // A filter keeps the unfiltered height, so the popover does not resize on each keystroke.
                .frame(height: trimmedFilter.isEmpty ? nil : unfilteredHeight, alignment: .top)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if trimmedFilter.isEmpty { unfilteredHeight = height }
                }
            }
            .onChange(of: filter) {
                rebuildItems()
                highlighted = trimmedFilter.isEmpty ? nil : 0
            }
            .onChange(of: choices) { rebuildItems() }
            .onChange(of: items) {
                // Typing highlights the first match, which may be scrolled out of view.
                if let highlighted, items.indices.contains(highlighted) {
                    proxy.scrollTo(items[highlighted].id)
                }
            }
            .onAppear { isFilterFocused = true }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        pick(at: item.index)
                    } label: {
                        LabelPickerRow(kind: item.kind, check: checkState(item), isHighlighted: highlighted == item.index)
                            .equatable()
                    }
                    .buttonStyle(.plain)
                    .modifier(CheckAccessibility(mark: checkState(item)))
                    .onHover { if $0 { highlighted = item.index } }
                    .id(item.id)
                }
            }
            .padding(Tokens.Space.s2)
        }
        .frame(maxHeight: Tokens.Popover.maxListHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func rebuildItems() {
        items = LabelPickerItem.matching(trimmedFilter, in: choices, canCreate: onCreate != nil)
    }

    private func pick(at index: Int) {
        guard items.indices.contains(index) else { return }
        switch items[index].kind {
        case .label(let choice): onPick(choice)
        case .create(let name): onCreate?(name)
        }
    }

    /// The arrow keys move the highlight and bring it into view. The pointer
    /// highlights without scrolling, so rows stay still under it.
    private func move(by step: Int, proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        let start = highlighted ?? (step > 0 ? -1 : items.count)
        let index = min(max(start + step, 0), items.count - 1)
        highlighted = index
        proxy.scrollTo(items[index].id)
    }

    private func checkState(_ item: LabelPickerItem) -> LabelSelection.State? {
        guard case .label(let choice) = item.kind, case .check(let state) = mark(choice) else { return nil }
        return state
    }
}

/// One row's content. It is equatable, so moving the highlight redraws only the
/// row it leaves and the row it enters.
private struct LabelPickerRow: View, Equatable {
    let kind: LabelPickerItem.Kind
    /// The checkbox state in Edit Labels. Move to has no checkboxes and passes nil.
    let check: LabelSelection.State?
    let isHighlighted: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.check == rhs.check && lhs.isHighlighted == rhs.isHighlighted
    }

    var body: some View {
        let textColor = isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : .primary
        HStack(spacing: Tokens.Space.s2) {
            switch kind {
            case .label(let choice):
                if let check {
                    Image(systemName: Self.checkbox(check))
                        .foregroundStyle(isHighlighted ? textColor : .accentColor)
                        .accessibilityHidden(true)
                }
                Image(systemName: choice.systemImage)
                    .symbolVariant(.fill)
                    .foregroundStyle(isHighlighted ? textColor : (Color(gmailHex: choice.backgroundColor) ?? .secondary))
                    .frame(width: Tokens.Control.icon)
                    .accessibilityHidden(true)
                Text(choice.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(choice.name)
            case .create(let name):
                Image(systemName: "plus")
                    .accessibilityHidden(true)
                Text("Create Label “\(name)”")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Create Label “\(name)”")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
        .contentShape(Rectangle())
    }

    private static func checkbox(_ state: LabelSelection.State) -> String {
        switch state {
        case .on: "checkmark.square.fill"
        case .off: "square"
        case .mixed: "minus.square.fill"
        }
    }
}

/// VoiceOver reads a checklist row as a toggle with its state.
private struct CheckAccessibility: ViewModifier {
    let mark: LabelSelection.State?

    func body(content: Content) -> some View {
        if let mark {
            content
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(Self.value(mark))
        } else {
            content
        }
    }

    private static func value(_ mark: LabelSelection.State) -> String {
        switch mark {
        case .on: "Checked"
        case .off: "Unchecked"
        case .mixed: "Mixed"
        }
    }
}
