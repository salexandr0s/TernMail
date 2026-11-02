import SwiftUI

/// The title and actions stay in place while a long form or error list scrolls.
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
    @State private var messageHeight: CGFloat = Tokens.Space.s8

    var body: some View {
        if let onExit {
            sheet.onExitCommand(perform: onExit)
        } else {
            sheet
        }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            TernPageHeader(title: title)
                .padding(.horizontal, Tokens.Workspace.pageGutter)
                .padding(.vertical, Tokens.Space.s4)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Divider()
            editorContent
                .background(Tokens.Surface.canvas)
            Divider()
            footer
                .layoutPriority(1)
        }
        .frame(width: width)
        .background(Tokens.Surface.muted)
    }

    @ViewBuilder private var editorContent: some View {
        if scrolls {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tokens.Workspace.pageGutter)
                    .padding(.vertical, Tokens.Space.s4)
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 0, idealHeight: min(contentHeight, Tokens.Settings.editorMaxContentHeight),
                   maxHeight: min(contentHeight, Tokens.Settings.editorMaxContentHeight))
        } else {
            // Native Forms supply their own scroll view and content margins.
            content
                .frame(minHeight: 0, idealHeight: Tokens.Settings.editorMaxContentHeight,
                       maxHeight: Tokens.Settings.editorMaxContentHeight)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !messages.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                            SettingsErrorLabel(message)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { messageHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(minHeight: 0, idealHeight: min(messageHeight, Tokens.Layout.quoteMaxHeight),
                       maxHeight: min(messageHeight, Tokens.Layout.quoteMaxHeight))
                .padding(.horizontal, Tokens.Workspace.pageGutter)
                .padding(.top, Tokens.Space.s3)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Issues to resolve")
            }
            HStack(spacing: Tokens.Space.s2) {
                Spacer(minLength: 0)
                actions
            }
            .padding(.horizontal, Tokens.Workspace.pageGutter)
            .padding(.vertical, Tokens.Space.s4)
            .fixedSize(horizontal: false, vertical: true)
        }
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
