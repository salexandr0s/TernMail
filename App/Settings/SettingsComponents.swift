import SwiftUI

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
            .padding(.horizontal, Tokens.Workspace.pageGutter)
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
