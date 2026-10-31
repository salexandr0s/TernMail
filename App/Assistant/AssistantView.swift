import AppKit
import SwiftUI

/// The sidebar and detached window share their conversation and unfinished input.
struct AssistantView: View {
    @Bindable var model: AssistantModel
    let onOpenSource: (AssistantSource) -> Void
    var onExpand: (() -> Void)?
    var onDetach: (() -> Void)?
    var onClose: (() -> Void)?
    /// The Assistant window shows the header's actions in its toolbar instead.
    var isDetached = false

    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isComposerFocused: Bool
    @FocusState private var focusedToolbarButton: String?
    @State private var hasPlacedInitialFocus = false
    @State private var showsSettings = false
    @State private var scrollRequest = UUID()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if !isDetached { header }
                scopePicker
            }
            .padding(.top, isDetached ? Tokens.Space.s3 : 0)
            .background(Tokens.Surface.muted)
            Divider()
            AssistantConversationView(model: model, scrollRequest: scrollRequest, onOpenSource: openSource,
                                      onOpenDraft: { openWindow(id: ComposeWindow.sceneID, value: $0) }) {
                AssistantWelcomeView(model: model, setup: setupPrompt, onSettings: { showsSettings = true }) { suggestion in
                    scrollRequest = UUID()
                    model.run(suggestion)
                    isComposerFocused = true
                }
            }
            composer
        }
        .background(Tokens.Surface.primary)
        .task {
            guard !hasPlacedInitialFocus else { return }
            // Let the native field join the window before assigning focus.
            await Task.yield()
            guard !Task.isCancelled, !showsSettings else { return }
            hasPlacedInitialFocus = true
            isComposerFocused = true
        }
        .task { await model.refreshConnection() }
        .onChange(of: model.connection.connectionRevision) {
            model.refreshAccess()
            Task { await model.refreshConnection() }
        }
        .onChange(of: model.availableAccounts.map(\.id)) { model.refreshAccess() }
        .sheet(isPresented: $showsSettings) {
            AssistantSettingsView(model: model, showsIntroduction: false, isSheet: true)
        }
        .modifier(AssistantWindowToolbar(isEnabled: isDetached, subtitle: modelName,
                                         onNewChat: startNewChat, onSettings: { showsSettings = true }))
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s2) {
            ChatGPTBrand(size: Tokens.Space.s5)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                Text("Assistant").font(.headline).lineLimit(1)
                Text(modelName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(modelName)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            HStack(spacing: Tokens.Space.s0_5) {
                iconButton("New chat", symbol: "plus", action: startNewChat)
                Menu {
                    Button("Assistant settings", systemImage: "gearshape") { showsSettings = true }
                    if let onDetach { Button("Open in a window", systemImage: "macwindow", action: onDetach) }
                    if let onExpand {
                        Button("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right", action: onExpand)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                .help("Assistant options").accessibilityLabel("Assistant options")
                if let onClose { iconButton("Close assistant", symbol: "xmark", action: onClose) }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Tokens.Space.s4).padding(.top, Tokens.Space.s3).padding(.bottom, Tokens.Space.s2)
    }

    private var scopePicker: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "envelope")
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Menu {
                Picker("Mail scope", selection: $model.selectedScope) {
                    ForEach(AssistantScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.selectedScope.title).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuIndicator(.visible).menuStyle(.borderlessButton).controlSize(.small)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Mail scope").accessibilityValue(model.selectedScope.title)
            .help("Mail scope: \(model.selectedScope.title). Calendar access is managed separately in settings.")
            Divider().frame(height: Tokens.Space.s4)
            Button { showsSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            .buttonStyle(.borderless).fixedSize()
            .help("Manage mail and calendar access")
            .accessibilityLabel("Manage assistant access. \(model.enabledAccountIDs.count) enabled mail accounts")
        }
        .font(.caption)
        .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s1)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .strokeBorder(outlineColor, lineWidth: Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, Tokens.Space.s4).padding(.bottom, Tokens.Space.s3)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                TextField(model.messages.isEmpty ? "Ask about mail or calendar…" : "Ask a follow-up…",
                          text: $model.composerText, axis: .vertical)
                    .font(.body).textFieldStyle(.plain).lineLimit(2...6)
                    .focused($isComposerFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
                           editor.hasMarkedText() { return .ignored }
                        if press.modifiers.contains(.shift) {
                            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                            editor.insertNewlineIgnoringFieldEditor(nil)
                            return .handled
                        }
                        guard !press.modifiers.contains(.option),
                              !press.modifiers.contains(.control) else { return .ignored }
                        submit()
                        return .handled
                    }
                    .accessibilityLabel("Message to assistant")
                    .accessibilityHint("Return to send. Shift-Return for a new line.")
                HStack(spacing: Tokens.Space.s2) {
                    composerHint
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Tokens.Space.s2)
                    if model.isRunning {
                        Button { model.stop() } label: {
                            Image(systemName: "stop.fill")
                                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.circle)
                        .help("Stop response").accessibilityLabel("Stop response")
                    } else {
                        Button(action: submit) {
                            Image(systemName: "arrow.up").font(.body.weight(.semibold))
                                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSubmit).help("Send message (Return or ⌘ Return)")
                        .accessibilityLabel("Send message")
                    }
                }
            }
            .padding(Tokens.Space.s3)
            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                    .strokeBorder(isComposerFocused ? Color.accentColor : outlineColor,
                                  lineWidth: isComposerFocused ? Tokens.Border.focus : Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
            .padding(Tokens.Space.s3)
            .frame(maxWidth: Tokens.Assistant.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Tokens.Surface.muted)
    }

    @ViewBuilder private var composerHint: some View {
        if model.isRunning {
            Label("Working…", systemImage: "ellipsis")
        } else if let setupPrompt {
            Button(setupPrompt.action, action: { showsSettings = true }).buttonStyle(.link)
        } else {
            Text("Return to send · ⇧ Return for a new line")
        }
    }

    private var modelName: String {
        model.models.first(where: { $0.id == model.selectedModelID })?.displayName ?? "ChatGPT"
    }

    private var outlineColor: Color { contrast == .increased ? .primary : Tokens.Surface.border }

    private var setupPrompt: AssistantSetupPrompt? {
        if !model.connection.canUsePlan {
            return .init(title: "Connect ChatGPT", detail: "Use your ChatGPT account, then choose the mail and calendars the assistant can read.", action: "Set up assistant", systemImage: "person.crop.circle.badge.plus")
        }
        if !model.hasAssistantDataAccess {
            return .init(title: "Choose what to share", detail: "Enable a mail account or calendar in assistant settings.", action: "Manage access", systemImage: "slider.horizontal.3")
        }
        if model.selectedModelID.isEmpty {
            return .init(title: "Choose a model", detail: "Select a ChatGPT model in assistant settings to start a conversation.", action: "Choose model", systemImage: "sparkle")
        }
        return nil
    }

    private var canSubmit: Bool {
        setupPrompt == nil && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit, !model.isRunning else { return }
        scrollRequest = UUID()
        model.send(model.composerText)
        if model.isRunning { model.composerText = "" }
        isComposerFocused = true
    }

    private func startNewChat() {
        model.newChat()
        scrollRequest = UUID()
        isComposerFocused = true
    }

    private func openSource(_ source: AssistantSource) {
        onOpenSource(source)
        openWindow(id: "main")
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(AssistantToolbarButtonStyle(isFocused: focusedToolbarButton == title))
        .focused($focusedToolbarButton, equals: title)
        .help(title).accessibilityLabel(title)
    }
}

private struct AssistantToolbarButtonStyle: ButtonStyle {
    let isFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isFocused || isHovered || configuration.isPressed ? Tokens.Surface.primary : .clear,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay {
                if isFocused || (contrast == .increased && (isHovered || configuration.isPressed)) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(isFocused ? Color.accentColor : .primary,
                                      lineWidth: isFocused ? Tokens.Border.focus : Tokens.Border.hairline)
                        .allowsHitTesting(false)
                }
            }
            .onHover { isHovered = $0 }
    }
}

/// The Assistant window's toolbar holds what the sidebar header shows. The
/// sidebar sits in the main window, whose customizable toolbar it must not join.
private struct AssistantWindowToolbar: ViewModifier {
    let isEnabled: Bool
    let subtitle: String
    let onNewChat: () -> Void
    let onSettings: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("New Chat", systemImage: "plus.bubble", action: onNewChat)
                            .help("New Chat")
                        Button("Assistant Settings", systemImage: "gearshape", action: onSettings)
                            .help("Assistant Settings")
                    }
                }
        } else {
            content
        }
    }
}
