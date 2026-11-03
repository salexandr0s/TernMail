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
    @FocusState private var isComposerFocused: Bool
    @State private var hasPlacedInitialFocus = false
    /// Where focus was as the panel appeared, so a composer that turns on
    /// later leaves alone focus the user has moved since.
    @State private var responderAtAppear: ObjectIdentifier?
    @State private var showsSettings = false
    @State private var scrollRequest = UUID()
    @State private var confirmsNewChat = false

    var body: some View {
        VStack(spacing: 0) {
            if !isDetached { header }
            AssistantConversationView(model: model, scrollRequest: scrollRequest, onOpenSource: openSource,
                                      onOpenDraft: { openWindow(id: ComposeWindow.sceneID, value: $0) }) {
                AssistantWelcomeView(model: model, setup: setupPrompt, onSettings: performSetupAction) { suggestion in
                    scrollRequest = UUID()
                    model.run(suggestion)
                    isComposerFocused = true
                }
            }
            AssistantScopeNotice(model: model)
            AssistantComposer(model: model, setup: setupPrompt, canSubmit: canSubmit, isFocused: $isComposerFocused,
                              onSubmit: submit, onSettings: { showsSettings = true }, onSetup: performSetupAction)
                .padding(Tokens.Space.s3)
                .frame(maxWidth: Tokens.Assistant.contentWidth)
                .frame(maxWidth: .infinity)
        }
        .background(Tokens.Surface.muted)
        .onKeyPress(.escape) { closeOnEscape() }
        .task {
            guard !hasPlacedInitialFocus else { return }
            responderAtAppear = NSApp.keyWindow?.firstResponder.map(ObjectIdentifier.init)
            // Let the native field join the window before assigning focus.
            await Task.yield()
            guard !Task.isCancelled else { return }
            placeInitialFocus()
        }
        // A restored connection turns the composer on later.
        .onChange(of: setupPrompt == nil) { if isFocusUnmoved { placeInitialFocus() } }
        // Setup finished in the settings sheet hands focus to the composer.
        .onChange(of: showsSettings) { if !showsSettings { placeInitialFocus() } }
        .task { await model.refreshConnection() }
        .onChange(of: model.connection.connectionRevision) {
            model.refreshAccess()
            Task { await model.refreshConnection() }
        }
        .onChange(of: model.availableAccounts.map(\.id)) { model.refreshAccess() }
        .sheet(isPresented: $showsSettings) {
            AssistantSettingsView(model: model, isSheet: true)
        }
        .confirmationDialog("Start a new chat?", isPresented: $confirmsNewChat, titleVisibility: .visible) {
            Button("Start New Chat", role: .destructive, action: confirmNewChat)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the current conversation and stops any response. Your unfinished message will be kept.")
        }
        .modifier(AssistantWindowToolbar(isEnabled: isDetached, subtitle: "ChatGPT",
                                         onNewChat: startNewChat, onSettings: { showsSettings = true }))
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s2) {
            ChatGPTBrand(size: Tokens.Space.s5)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .ternOutline(radius: Tokens.Radius.md)
                .accessibilityHidden(true)
            Text("ChatGPT").font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: Tokens.Space.s0_5) {
                iconButton("New Chat", symbol: "plus", action: startNewChat)
                Menu {
                    Button("Assistant Settings…", systemImage: "gearshape") { showsSettings = true }
                    if let onDetach { Button("Open in a Window", systemImage: "macwindow", action: onDetach) }
                    if let onExpand {
                        Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: onExpand)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                .ternHover()
                .help("Assistant Options").accessibilityLabel("Assistant Options")
                if let onClose { iconButton("Close Assistant", symbol: "xmark", action: onClose) }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Tokens.Space.s4).padding(.top, Tokens.Space.s3).padding(.bottom, Tokens.Space.s2)
        .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
    }

    private var setupPrompt: AssistantSetupPrompt? {
        if !model.connection.canUsePlan {
            return .init(title: "Connect ChatGPT", detail: "Use your ChatGPT account, then choose the mail and calendars the assistant can read.", action: "Set up assistant", systemImage: "person.crop.circle.badge.plus")
        }
        if !model.hasAssistantDataAccess {
            return .init(title: "Choose what to share", detail: "Enable a mail account or calendar in assistant settings.", action: "Manage access", systemImage: "slider.horizontal.3")
        }
        if !model.isModelReady {
            return .init(title: model.isLoadingModels ? "Loading models" : "Models unavailable",
                         detail: model.modelErrorMessage ?? "Tern needs an available ChatGPT model to start a conversation.",
                         action: model.isLoadingModels ? "Loading models…" : "Retry loading models", systemImage: "sparkle")
        }
        return nil
    }

    private var canSubmit: Bool {
        setupPrompt == nil && !model.hasPendingScopeChange
            && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The composer takes focus once, as soon as it can be used.
    private func placeInitialFocus() {
        guard !hasPlacedInitialFocus, !showsSettings, setupPrompt == nil else { return }
        hasPlacedInitialFocus = true
        isComposerFocused = true
    }

    /// Nothing has focus, or what had it as the panel appeared still does.
    private var isFocusUnmoved: Bool {
        guard let window = NSApp.keyWindow, let responder = window.firstResponder else { return true }
        return responder === window || ObjectIdentifier(responder) == responderAtAppear
    }

    private func submit() {
        guard canSubmit, !model.isRunning else { return }
        scrollRequest = UUID()
        model.send(model.composerText)
        if model.isRunning { model.composerText = "" }
        isComposerFocused = true
    }

    /// Esc closes the sidebar unless the composer holds a message or an unfinished
    /// input-method entry. The detached window stays open, like any window.
    private func closeOnEscape() -> KeyPress.Result {
        guard let onClose, model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ignored
        }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextInputClient, editor.hasMarkedText() { return .ignored }
        onClose()
        return .handled
    }

    private func startNewChat() {
        if !model.messages.isEmpty || model.isRunning { confirmsNewChat = true }
        else { confirmNewChat() }
    }

    private func confirmNewChat() {
        model.startChatWithCurrentScope()
        scrollRequest = UUID()
        isComposerFocused = true
    }

    private func performSetupAction() {
        if model.connection.canUsePlan, model.hasAssistantDataAccess, !model.isModelReady {
            guard !model.isLoadingModels else { return }
            Task { await model.refreshConnection() }
        } else { showsSettings = true }
    }

    private func openSource(_ source: AssistantSource) {
        onOpenSource(source)
        openWindow(id: RootView.sceneID)
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(AssistantToolbarButtonStyle())
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .help(title).accessibilityLabel(title)
    }
}

/// Hover and press feedback for the header's icon buttons. Keyboard focus
/// shows the system focus ring.
private struct AssistantToolbarButtonStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isHovered || configuration.isPressed ? Tokens.Assistant.chatBubble : .clear,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay {
                if contrast == .increased && (isHovered || configuration.isPressed) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(Color.primary, lineWidth: Tokens.Border.hairline)
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
