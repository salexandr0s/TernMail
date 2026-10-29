import GmailAPI
import SwiftUI

struct LabelColorPicker: View {
    @Binding var selection: LabelColor?
    @State private var showsAllColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack {
                Text("Color").font(.subheadline.weight(.semibold))
                Spacer()
                Button("All colors…") { showsAllColors = true }
                    .buttonStyle(.link)
                    .focusable()
                    .onKeyPress(keys: [.return, .space]) { _ in
                        showsAllColors = true
                        return .handled
                    }
            }
            // A bright and a soft shade of each hue; the full grid stays one click away.
            LabelColorGrid(selection: $selection, indices: Array(8..<16) + Array(24..<32))
        }
        .popover(isPresented: $showsAllColors, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                PopupHeader(title: "Label color", systemImage: "paintpalette")
                LabelColorGrid(selection: $selection, focusesSelection: true, onCancel: { showsAllColors = false })
                    .padding(.horizontal, Tokens.Space.s4)
                    .padding(.bottom, Tokens.Space.s4)
                PopupFooter {
                    Button("Done") { showsAllColors = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .frame(width: Tokens.Popover.width)
        }
    }
}

/// Every swatch has the same hit area; grids fill the available width.
struct LabelColorGrid: View {
    @Binding var selection: LabelColor?
    var indices = Array(LabelColor.grid.indices)
    var focusesSelection = false
    var onCancel: (() -> Void)? = nil
    @FocusState private var focusedChoice: Int?
    // Track arrow-key intent separately from delayed AppKit focus updates,
    // so a rapid Return uses the last arrow move. Tab and pointer actions reset it.
    @State private var pendingChoice: Int?

    /// The No color control follows the swatches in the keyboard order.
    private let noColor = -1
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.s1), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            LazyVGrid(columns: columns, spacing: Tokens.Space.s1) {
                ForEach(indices, id: \.self) { index in
                    swatch(at: index)
                }
            }
            HStack {
                Button { pendingChoice = nil; selection = nil } label: {
                    Label("No color", systemImage: selection == nil ? "checkmark.circle.fill" : "circle.slash")
                }
                .buttonStyle(.link)
                .focusable()
                .focused($focusedChoice, equals: noColor)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space, .tab]) {
                    handleKey($0.key, at: noColor)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("No color")
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(selection == nil ? .isSelected : [])
                Spacer()
                if let selection {
                    Text(Self.name(for: selection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guard focusesSelection else { return }
            await Task.yield()
            focusedChoice = selection == nil ? noColor : indices.first {
                LabelColor.grid[$0].backgroundColor == selection?.backgroundColor
            } ?? indices.first
        }
        .onKeyPress(.escape) {
            guard let onCancel else { return .ignored }
            onCancel()
            return .handled
        }
        .onChange(of: focusedChoice) { _, focus in
            if focus == nil { pendingChoice = nil }
        }
    }

    private func swatch(at index: Int) -> some View {
        let color = LabelColor.grid[index]
        let name = Self.name(row: index / 8, column: index % 8)
        let selected = selection?.backgroundColor == color.backgroundColor
        return Button { pendingChoice = nil; selection = color } label: {
            Circle()
                .fill(Color(gmailHex: color.backgroundColor) ?? .clear)
                .overlay { Circle().strokeBorder(.separator, lineWidth: Tokens.Border.hairline) }
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(gmailHex: color.textColor) ?? .primary)
                    }
                }
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .padding(Tokens.Space.s1)
                .overlay {
                    if selected {
                        Circle().strokeBorder(.tint, lineWidth: Tokens.Border.focus)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedChoice, equals: index)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space, .tab]) {
            handleKey($0.key, at: index)
        }
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func handleKey(_ key: KeyEquivalent, at choice: Int) -> KeyPress.Result {
        if key == .tab {
            pendingChoice = nil
            return .ignored
        }
        let choice = pendingChoice ?? choice
        if key == .return || key == .space {
            selection = choice == noColor ? nil : LabelColor.grid[choice]
            return .handled
        }
        let choices = indices + [noColor]
        let step = switch key {
        case .leftArrow: -1
        case .rightArrow: 1
        case .upArrow: -8
        default: 8
        }
        let position = choices.firstIndex(of: choice) ?? 0
        let target = choices[min(max(position + step, 0), choices.count - 1)]
        pendingChoice = target
        focusedChoice = target
        return .handled
    }

    static func name(for color: LabelColor) -> String {
        guard let index = LabelColor.grid.firstIndex(where: { $0.backgroundColor == color.backgroundColor }) else {
            return "Custom color"
        }
        return name(row: index / 8, column: index % 8)
    }

    static func name(row: Int, column: Int) -> String {
        let grays = ["Black", "Darkest gray", "Dark gray", "Gray", "Light gray", "Lighter gray", "Lightest gray", "White"]
        let hues = ["red", "orange", "yellow", "green", "mint", "blue", "purple", "pink"]
        let shades = ["Bright", "Palest", "Pale", "Medium", "Deep", "Dark", "Darkest"]
        guard row > 0 else { return grays[column % grays.count] }
        return "\(shades[(row - 1) % shades.count]) \(hues[column % hues.count])"
    }
}

struct LabelIconPicker: View {
    @Binding var selection: String
    let onChoose: () -> Void
    @FocusState private var focusedIcon: String?
    @State private var pendingIcon: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.s1), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            PopupHeader(title: "Label icon", systemImage: "square.grid.2x2")
            LazyVGrid(columns: columns, spacing: Tokens.Space.s2) {
                ForEach(LabelAppearance.icons) { icon in
                    Button {
                        pendingIcon = nil
                        selection = icon.systemImage
                        onChoose()
                    } label: {
                        Image(systemName: icon.systemImage)
                            .font(.title3)
                            .foregroundStyle(selection == icon.systemImage ? Color.accentColor : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: Tokens.Control.iconButton)
                            .background {
                                if selection == icon.systemImage {
                                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                                        .fill(Tokens.Surface.muted)
                                        .strokeBorder(.tint, lineWidth: Tokens.Border.focus)
                                }
                            }
                            .contentShape(Rectangle())
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedIcon, equals: icon.systemImage)
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space, .tab]) {
                        handleKey($0.key, at: icon.systemImage)
                    }
                    .help(icon.name)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(icon.name)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(selection == icon.systemImage ? .isSelected : [])
                }
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.bottom, Tokens.Space.s4)
            PopupFooter {
                Button("Done", action: onChoose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: Tokens.Popover.width)
        .task {
            await Task.yield()
            focusedIcon = LabelAppearance.icons.first { $0.systemImage == selection }?.systemImage
                ?? LabelAppearance.icons.first?.systemImage
        }
        .onKeyPress(.escape) {
            onChoose()
            return .handled
        }
        .onChange(of: focusedIcon) { _, focus in
            if focus == nil { pendingIcon = nil }
        }
    }

    private func handleKey(_ key: KeyEquivalent, at icon: String) -> KeyPress.Result {
        if key == .tab {
            pendingIcon = nil
            return .ignored
        }
        let icon = pendingIcon ?? icon
        if key == .return || key == .space {
            selection = icon
            onChoose()
            return .handled
        }
        let step = switch key {
        case .leftArrow: -1
        case .rightArrow: 1
        case .upArrow: -6
        default: 6
        }
        let icons = LabelAppearance.icons
        let position = icons.firstIndex { $0.systemImage == icon } ?? 0
        let target = icons[min(max(position + step, 0), icons.count - 1)].systemImage
        pendingIcon = target
        focusedIcon = target
        return .handled
    }
}
