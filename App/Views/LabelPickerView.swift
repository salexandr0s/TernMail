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
            HStack {
                Label("Edit Labels", systemImage: "tag")
                    .font(.headline)
                Spacer()
            }
            .padding([.horizontal, .top], Tokens.Space.s3)
            FilteredLabelList(
                choices: labels,
                mark: { .check(selection.state(of: $0.id)) },
                onPick: { selection.toggle($0.id) },
                onCreate: { onCreateLabel($0, selection.change) }
            )
            Divider()
            HStack {
                Spacer()
                Button("Apply") { onApply(selection.change) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(selection.change.isEmpty)
                    .help("Apply (⌘Return)")
            }
            .padding(Tokens.Space.s3)
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
            HStack {
                Label("Move to", systemImage: "folder")
                    .font(.headline)
                Spacer()
            }
            .padding([.horizontal, .top], Tokens.Space.s3)
            FilteredLabelList(choices: targets, mark: { _ in .none }, onPick: { onMove($0.id) }, onCreate: nil)
        }
        .frame(width: Tokens.Popover.width)
    }
}

/// A filter field over a list of labels that works like a menu: the arrow
/// keys move the highlight, Return picks it and the pointer highlights too.
private struct FilteredLabelList: View {
    enum Mark {
        case none
        case check(LabelSelection.State)
    }

    private enum Item: Identifiable {
        case label(LabelChoice)
        case create(String)

        var id: String {
            switch self {
            case .label(let choice): "label:\(choice.id)"
            case .create: "create"
            }
        }
    }

    let choices: [LabelChoice]
    let mark: (LabelChoice) -> Mark
    let onPick: (LabelChoice) -> Void
    /// Offered when the filter names no label. Nil hides it.
    let onCreate: ((String) -> Void)?

    @State private var filter = ""
    @State private var highlighted: Int?
    @FocusState private var isFilterFocused: Bool

    private var trimmedFilter: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var items: [Item] {
        let query = trimmedFilter
        guard !query.isEmpty else { return choices.map(Item.label) }
        var items = choices.filter { $0.name.localizedCaseInsensitiveContains(query) }.map(Item.label)
        let exists = choices.contains { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        if onCreate != nil, !exists { items.append(.create(query)) }
        return items
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            TextField("Filter labels", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($isFilterFocused)
                .onSubmit {
                    if let highlighted { pick(items, at: highlighted) }
                }
                .onKeyPress(.downArrow) {
                    move(by: 1, count: items.count)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1, count: items.count)
                    return .handled
                }
                .padding(Tokens.Space.s3)
            Divider()
            if items.isEmpty {
                Label("No matching labels", systemImage: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.s4)
            } else {
                list(items)
            }
        }
        .onChange(of: filter) {
            highlighted = trimmedFilter.isEmpty ? nil : 0
        }
        .onAppear { isFilterFocused = true }
    }

    private func list(_ items: [Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            pick(items, at: index)
                        } label: {
                            row(item, isHighlighted: highlighted == index)
                        }
                        .buttonStyle(.plain)
                        .modifier(CheckAccessibility(mark: Self.checkState(item, mark: mark)))
                        .onHover { if $0 { highlighted = index } }
                        .id(item.id)
                    }
                }
                .padding(Tokens.Space.s1)
            }
            .frame(maxHeight: Tokens.Popover.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) {
                if let highlighted, items.indices.contains(highlighted) {
                    proxy.scrollTo(items[highlighted].id)
                }
            }
        }
    }

    private func row(_ item: Item, isHighlighted: Bool) -> some View {
        let textColor = isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : .primary
        return HStack(spacing: Tokens.Space.s2) {
            switch item {
            case .label(let choice):
                if case .check(let state) = mark(choice) {
                    Image(systemName: Self.checkbox(state))
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

    private func pick(_ items: [Item], at index: Int) {
        guard items.indices.contains(index) else { return }
        switch items[index] {
        case .label(let choice): onPick(choice)
        case .create(let name): onCreate?(name)
        }
    }

    private func move(by step: Int, count: Int) {
        guard count > 0 else { return }
        let start = highlighted ?? (step > 0 ? -1 : count)
        highlighted = min(max(start + step, 0), count - 1)
    }

    private static func checkState(_ item: Item, mark: (LabelChoice) -> Mark) -> LabelSelection.State? {
        guard case .label(let choice) = item, case .check(let state) = mark(choice) else { return nil }
        return state
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
