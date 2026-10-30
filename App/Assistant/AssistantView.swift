import SwiftUI

/// The sidebar and detached window share their conversation and unfinished input.
struct AssistantView: View {
    @Bindable var model: AssistantModel
    let onOpenSource: (AssistantSource) -> Void
    var onExpand: (() -> Void)?
    var onDetach: (() -> Void)?
    var onClose: (() -> Void)?

    @Environment(\.openWindow) private var openWindow
    @FocusState private var isComposerFocused: Bool
    @State private var hasPlacedInitialFocus = false
    @State private var showsSettings = false
    @State private var scrollRequest = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scopePicker
            Divider()
            AssistantConversationView(model: model, scrollRequest: scrollRequest, onOpenSource: openSource,
                                      onOpenDraft: { openWindow(id: ComposeWindow.sceneID, value: $0) }) {
                AssistantWelcomeView(model: model, onSettings: { showsSettings = true }) { suggestion in
                    scrollRequest = UUID()
                    model.run(suggestion)
                    isComposerFocused = true
                }
            }
            Divider()
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
            VStack(spacing: 0) {
                HStack {
                    Text("Assistant settings").font(.headline)
                    Spacer()
                    Button("Done") { showsSettings = false }.keyboardShortcut(.cancelAction)
                }
                .padding(Tokens.Space.s4)
                Divider()
                AssistantSettingsView(model: model)
            }
            .frame(width: Tokens.Layout.settingsWidth, height: Tokens.Assistant.settingsHeight)
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s2) {
            ChatGPTBrand(size: Tokens.Space.s6)
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                Text("Assistant").font(.headline)
                Text(model.models.first(where: { $0.id == model.selectedModelID })?.displayName ?? "ChatGPT")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            iconButton("New chat", symbol: "square.and.pencil") {
                model.newChat()
                scrollRequest = UUID()
                isComposerFocused = true
            }
            Menu {
                Button("Assistant settings", systemImage: "gearshape") { showsSettings = true }
                if let onDetach { Button("Open in a window", systemImage: "macwindow", action: onDetach) }
                if let onExpand {
                    Button("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right", action: onExpand)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
            }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
            .help("Assistant options").accessibilityLabel("Assistant options")
            if let onClose { iconButton("Close assistant", symbol: "xmark", action: onClose) }
        }
        .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
    }

    private var scopePicker: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "envelope").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker("Mail scope", selection: $model.selectedScope) {
                ForEach(AssistantScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().accessibilityLabel("Mail scope")
            Spacer(minLength: 0)
            Button { showsSettings = true } label: {
                Label("\(model.enabledAccountIDs.count)", systemImage: "person.crop.circle")
            }
            .buttonStyle(.borderless)
            .help("Choose which mail accounts the assistant can use")
            .accessibilityLabel("\(model.enabledAccountIDs.count) enabled mail accounts. Manage access")
        }
        .font(.caption)
        .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(alignment: .bottom, spacing: Tokens.Space.s2) {
                TextField("Ask about your mail or calendar…", text: $model.composerText, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6)
                    .focused($isComposerFocused)
                    .accessibilityLabel("Message to assistant")
                    .padding(.vertical, Tokens.Space.s2)
                if model.isRunning {
                    Button("Stop response", systemImage: "stop.fill") { model.stop() }
                        .labelStyle(.iconOnly).buttonStyle(.bordered).buttonBorderShape(.circle)
                        .controlSize(.large).help("Stop response")
                } else {
                    Button("Send message", systemImage: "arrow.up", action: submit)
                        .labelStyle(.iconOnly).buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                        .controlSize(.large).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSubmit).help("Send message (⌘ Return)")
                }
            }
            .padding(Tokens.Space.s2)
            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                    .strokeBorder(isComposerFocused ? Color.accentColor : Tokens.Surface.border,
                                  lineWidth: isComposerFocused ? Tokens.Border.focus : Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
            HStack {
                if let prerequisite {
                    Button(prerequisite) { showsSettings = true }.buttonStyle(.link)
                } else {
                    Text("⌘ Return to send").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: Tokens.Assistant.contentWidth)
        .frame(maxWidth: .infinity)
    }

    private var prerequisite: String? {
        if !model.connection.canUsePlan { return "Connect ChatGPT to start" }
        if !model.hasAssistantDataAccess { return "Enable mail or calendar access to start" }
        if model.selectedModelID.isEmpty { return "Choose a ChatGPT model" }
        return nil
    }

    private var canSubmit: Bool {
        prerequisite == nil && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit, !model.isRunning else { return }
        scrollRequest = UUID()
        model.send(model.composerText)
        if model.isRunning { model.composerText = "" }
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}
