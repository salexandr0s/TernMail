import SwiftUI

/// The sidebar and detached window share their conversation and unfinished input.
struct AssistantView: View {
    @Bindable var model: AssistantModel
    let onOpenSource: (AssistantSource) -> Void
    var onExpand: (() -> Void)?
    var onDetach: (() -> Void)?
    var onClose: (() -> Void)?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isComposerFocused: Bool
    @State private var hasPlacedInitialFocus = false
    @State private var showsSettings = false
    @State private var scrollRequest = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            scopePicker
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
        HStack(spacing: Tokens.Space.s3) {
            ChatGPTBrand(size: Tokens.Space.s6)
                .frame(width: Tokens.Space.s10, height: Tokens.Space.s10)
                .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                Text("Assistant").font(.headline)
                Text(modelName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(modelName)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            HStack(spacing: Tokens.Space.s0_5) {
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
        .padding(.horizontal, Tokens.Space.s4).padding(.top, Tokens.Space.s4).padding(.bottom, Tokens.Space.s3)
    }

    private var scopePicker: some View {
        HStack(spacing: Tokens.Space.s2) {
            Menu {
                Picker("Mail scope", selection: $model.selectedScope) {
                    ForEach(AssistantScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.selectedScope.title, systemImage: "envelope").lineLimit(1)
            }
            .menuIndicator(.visible).menuStyle(.borderlessButton).controlSize(.small)
            .padding(.horizontal, Tokens.Space.s2)
            .frame(height: Tokens.Control.iconButton)
            .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(Color.primary, lineWidth: Tokens.Border.hairline)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Mail scope").accessibilityValue(model.selectedScope.title)
            .help("Mail scope: \(model.selectedScope.title). Calendar access is managed separately in settings.")
            Spacer(minLength: 0)
            Button { showsSettings = true } label: {
                Label("Access", systemImage: "slider.horizontal.3")
                    .padding(.horizontal, Tokens.Space.s2)
                    .frame(height: Tokens.Control.iconButton)
            }
            .buttonStyle(.borderless).fixedSize()
            .help("Manage mail and calendar access")
            .accessibilityLabel("Manage assistant access. \(model.enabledAccountIDs.count) enabled mail accounts")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s4).padding(.bottom, Tokens.Space.s3)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                TextField("Ask about mail or calendar…", text: $model.composerText, axis: .vertical)
                    .font(.body).textFieldStyle(.plain).lineLimit(2...6)
                    .focused($isComposerFocused)
                    .accessibilityLabel("Message to assistant")
                HStack(spacing: Tokens.Space.s2) {
                    composerHint
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Tokens.Space.s2)
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
            }
            .padding(Tokens.Space.s3)
            .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                    .strokeBorder(isComposerFocused ? Color.accentColor : outlineColor,
                                  lineWidth: isComposerFocused ? Tokens.Border.focus : Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: Tokens.Assistant.contentWidth)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var composerHint: some View {
        if model.isRunning {
            Text("Replying…")
        } else if let setupPrompt {
            Button(setupPrompt.action, action: { showsSettings = true }).buttonStyle(.link)
        } else {
            Text("⌘ Return to send")
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
