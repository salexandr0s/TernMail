import SwiftUI

/// Sheets fit short forms and keep their actions visible when longer forms scroll.
struct SettingsEditorSheet<Content: View, Actions: View>: View {
    let title: String
    var width: CGFloat = Tokens.Settings.editorWidth
    var messages: [String] = []
    /// `false` when `content` is a form that scrolls on its own.
    var scrolls = true
    /// Runs on Esc when no Cancel button claims it; Done-only sheets use it.
    var onExit: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @State private var contentHeight: CGFloat = Tokens.Layout.settingsHeight

    var body: some View {
        if let onExit {
            sheet.onExitCommand(perform: onExit)
        } else {
            sheet
        }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if scrolls {
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Tokens.Space.s1)
                        .padding(.trailing, Tokens.Space.s2)
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { contentHeight = ceil(geometry.size.height) }
                                    .onChange(of: geometry.size.height) { _, height in
                                        contentHeight = ceil(height)
                                    }
                            }
                        }
                }
                .frame(height: min(contentHeight, Tokens.Settings.editorMaxContentHeight))
            } else {
                content
            }

            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Tokens.Status.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Tokens.Space.s2) {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .padding(Tokens.Space.s5)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Tokens.Surface.muted)
    }
}

extension SettingsEditorSheet where Actions == SettingsDoneButton {
    /// A sheet that applies changes as they are made. Return and Esc both close it.
    init(title: String, width: CGFloat = Tokens.Settings.editorWidth, messages: [String] = [],
         scrolls: Bool = true, onDone: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, width: width, messages: messages, scrolls: scrolls, onExit: onDone,
                  content: content, actions: { SettingsDoneButton(action: onDone) })
    }
}

/// The only button on a sheet that has nothing to cancel.
struct SettingsDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button("Done", action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }
}

/// Every pane is a grouped form, so labels and controls align the way they do
/// in System Settings.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Actions stay reachable while the settings above them scroll.
struct SettingsFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.vertical, Tokens.Space.s3)
            .background(Tokens.Surface.muted)
            .overlay(alignment: .top) { Divider() }
    }
}

struct SettingsControlRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control
                .labelsHidden()
        } label: {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? "")
    }
}

/// A switch for a setting that saves asynchronously. It shows the new value
/// while `onToggle` runs, then follows `isOn` again, so a failed save flips back.
struct SettingsAsyncToggleRow: View {
    let title: String
    let detail: String?
    let isOn: Bool
    let onToggle: @MainActor (Bool) async -> Void
    @State private var pending: Bool?

    init(_ title: String, detail: String? = nil, isOn: Bool, onToggle: @escaping @MainActor (Bool) async -> Void) {
        self.title = title
        self.detail = detail
        self.isOn = isOn
        self.onToggle = onToggle
    }

    var body: some View {
        SettingsToggleRow(title, detail: detail, isOn: Binding(pending ?? isOn, set: toggle))
    }

    private func toggle(_ value: Bool) {
        pending = value
        Task {
            await onToggle(value)
            // A later toggle may still be saving, so keep showing its value.
            if pending == value { pending = nil }
        }
    }
}

/// An error in a settings pane. The text is selectable so it can be copied into a report.
struct SettingsErrorLabel: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(Tokens.Status.error)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

struct SettingsNote: View {
    let text: String
    var systemImage: String = "info.circle"

    init(_ text: String, systemImage: String = "info.circle") {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
