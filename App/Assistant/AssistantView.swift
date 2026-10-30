import SwiftUI

/// The same conversation is shown in the compact panel and assistant window.
struct AssistantView: View {
    @Bindable var model: AssistantModel
    let onOpenSource: (AssistantSource) -> Void
    var onExpand: (() -> Void)?
    var onDetach: (() -> Void)?
    var onClose: (() -> Void)?

    @Environment(\.openWindow) private var openWindow
    @FocusState private var isComposerFocused: Bool
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scopePicker
            Divider()
            conversation
            Divider()
            composer
        }
        .background(Tokens.Surface.primary)
        .task { await model.refreshConnection() }
        .onChange(of: model.connection.connectionRevision) {
            model.refreshAccess()
            Task { await model.refreshConnection() }
        }
        .sheet(isPresented: $showsSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Assistant settings").font(.headline)
                    Spacer()
                    Button("Done") { showsSettings = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(Tokens.Space.s4)
                Divider()
                AssistantSettingsView(model: model)
            }
            .frame(width: Tokens.Layout.settingsWidth, height: Tokens.Layout.shortcutsHeight)
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s2) {
            Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
            Spacer(minLength: Tokens.Space.s2)
            iconButton("New chat", symbol: "square.and.pencil") {
                model.newChat()
                isComposerFocused = true
            }
            iconButton("Assistant settings", symbol: "gearshape") { showsSettings = true }
            if let onExpand {
                iconButton("Open assistant full screen", symbol: "arrow.up.left.and.arrow.down.right", action: onExpand)
            }
            if let onDetach {
                iconButton("Open assistant in a window", symbol: "macwindow", action: onDetach)
            }
            if let onClose {
                iconButton("Close assistant", symbol: "xmark", action: onClose)
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
    }

    private var scopePicker: some View {
        HStack(spacing: Tokens.Space.s2) {
            Picker("Mail scope", selection: $model.selectedScope) {
                ForEach(AssistantScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Mail scope")

            Spacer(minLength: Tokens.Space.s2)
            Button {
                showsSettings = true
            } label: {
                Label("Accounts", systemImage: "person.crop.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Choose which mail accounts the assistant can use")
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    if model.messages.isEmpty {
                        welcome
                    }
                    ForEach(model.messages) { message in
                        messageView(message)
                    }
                    if let status = model.statusText, model.isRunning {
                        HStack(spacing: Tokens.Space.s2) {
                            ProgressView().controlSize(.small)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: Tokens.Space.s1).id("assistant-bottom")
                }
                .padding(Tokens.Space.s4)
                .frame(maxWidth: Tokens.Layout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.messages.count) { proxy.scrollTo("assistant-bottom", anchor: .bottom) }
            .onChange(of: model.messages.last?.text) { proxy.scrollTo("assistant-bottom", anchor: .bottom) }
            .onChange(of: model.statusText) { proxy.scrollTo("assistant-bottom", anchor: .bottom) }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Ask about your mail")
                .font(.title3.weight(.semibold))
            if !model.connection.canUsePlan {
                Text("Connect your ChatGPT account, then choose the mail accounts the assistant can use.")
                    .foregroundStyle(.secondary)
                Button("Set up assistant") { showsSettings = true }
                    .buttonStyle(.borderedProminent)
            } else if model.enabledAccountIDs.isEmpty {
                Text("Choose a mail account before asking the assistant to read messages or prepare drafts.")
                    .foregroundStyle(.secondary)
                Button("Choose accounts") { showsSettings = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Answers include sources. Drafts open in Tern for you to review and send.")
                    .foregroundStyle(.secondary)
                ForEach(["What needs my attention?", "Summarize the selected thread", "Draft a reply to this message"], id: \.self) { suggestion in
                    Button(suggestion) {
                        model.composerText = suggestion
                        isComposerFocused = true
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Tokens.Space.s4)
    }

    private func messageView(_ message: AssistantMessage) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text(message.isUser ? "You" : "Assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if !message.text.isEmpty {
                Text(message.isUser ? AttributedString(message.text) : formatted(message.text))
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(message.sources) { source in
                let trimmedTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = trimmedTitle.isEmpty ? "No Subject" : trimmedTitle
                Button {
                    onOpenSource(source)
                    openWindow(id: "main")
                } label: {
                    Label(title, systemImage: source.partID == nil ? "envelope" : "paperclip")
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.link)
                .help(title)
                .accessibilityLabel("Open source: \(title)")
            }
            ForEach(message.draftIDs, id: \.self) { draftID in
                Button {
                    openWindow(id: ComposeWindow.sceneID, value: draftID)
                } label: {
                    Label("Open draft", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }
            if message.state == .cancelled {
                Text("Stopped").font(.caption).foregroundStyle(.secondary)
            } else if message.state == .failed {
                Text("Incomplete response").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.isUser ? Tokens.Surface.muted : Tokens.Surface.primary)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            TextField("Ask about your mail…", text: $model.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .focused($isComposerFocused)
                .accessibilityLabel("Message to assistant")
                .padding(Tokens.Space.s3)
                .background(Tokens.Surface.muted)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.md)
                        .strokeBorder(
                            isComposerFocused ? Color.accentColor : Tokens.Surface.border,
                            lineWidth: isComposerFocused ? Tokens.Border.focus : Tokens.Border.hairline
                        )
                        .allowsHitTesting(false)
                }
            HStack(spacing: Tokens.Space.s2) {
                Text("⌘ Return to send")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isRunning {
                    Button("Stop", systemImage: "stop.fill") { model.stop() }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Stops the current assistant response")
                } else {
                    Button("Send", systemImage: "arrow.up") { submit() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSubmit)
                }
            }
        }
        .padding(Tokens.Space.s3)
    }

    private var canSubmit: Bool {
        model.connection.canUsePlan && !model.enabledAccountIDs.isEmpty
            && !model.selectedModelID.isEmpty && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit, !model.isRunning else { return }
        model.send(model.composerText)
        if model.isRunning { model.composerText = "" }
        isComposerFocused = true
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }

    /// Mail sources have their own validated buttons; model-generated URLs stay text.
    private func formatted(_ text: String) -> AttributedString {
        guard var result = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        let links = result.runs.compactMap { $0.link == nil ? nil : $0.range }
        for range in links { result[range].link = nil }
        return result
    }
}
