import SwiftUI

/// Sheets fit short forms and keep their actions visible when longer forms scroll.
struct SettingsEditorSheet<Content: View, Actions: View>: View {
    let title: String
    var width: CGFloat = Tokens.Settings.editorWidth
    var messages: [String] = []
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @State private var contentHeight: CGFloat = Tokens.Layout.settingsHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

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

            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.caption).foregroundStyle(.red)
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

/// A common reading width and scroll container for settings with custom rows.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                content
            }
            .frame(maxWidth: Tokens.Settings.contentWidth, alignment: .leading)
            .padding(Tokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage _: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Space.s1)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsSurface()
        }
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
        HStack(spacing: Tokens.Space.s4) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.body)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .labelsHidden()
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s2)
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
        SettingsControlRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityHint(detail ?? "")
        }
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

struct SettingsTabBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            content
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.top, Tokens.Space.s3)
        .padding(.bottom, Tokens.Space.s1)
    }
}

struct SettingsRowLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(title)
                .font(.body)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(
                colorScheme == .dark ? Color.primary.opacity(Tokens.Settings.groupTint) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.md)
            )
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: Tokens.Radius.md)
                        .strokeBorder(Color.primary, lineWidth: Tokens.Border.hairline)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func settingsSurface() -> some View { modifier(SettingsSurface()) }
}
