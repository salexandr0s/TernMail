import AppKit
import SwiftUI

/// The small bar leaves the message editable. Its popover holds longer replies
/// and the full suggestion without making the compose window taller.
struct ComposeAssistantView: View {
    @Bindable var model: ComposeAssistantModel
    let assistant: AssistantModel
    let onClose: () -> Void

    @State private var showsConversation = false
    @State private var showsSettings = false
    @FocusState private var focusedInput: Input?

    private enum Input: Hashable { case bar, conversation }

    var body: some View {
        VStack(spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(model.isRunning ? (model.statusText ?? "Thinking…") : model.contextDescription)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(model.contextDescription)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Button {
                    showsConversation.toggle()
                } label: {
                    Label(conversationTitle, systemImage: conversationSymbol)
                        .labelStyle(.iconOnly)
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                }
                .buttonStyle(.borderless).controlSize(.small)
                .help(conversationTitle)
                .accessibilityLabel(conversationTitle)
                .popover(isPresented: $showsConversation, arrowEdge: .top) { conversation }
                iconButton("Assistant Settings", symbol: "slider.horizontal.3") { showsSettings = true }
                iconButton("Close compose assistant", symbol: "xmark", action: onClose)
            }
            HStack(alignment: .bottom, spacing: Tokens.Space.s2) {
                requestField(.bar)
                    .frame(minWidth: 0, maxWidth: .infinity)
                requestButton
            }
        }
        .padding(Tokens.Space.s3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .ternOutline(radius: Tokens.Radius.lg)
        .shadow(color: Tokens.Shadow.mdColor, radius: Tokens.Shadow.mdRadius, y: Tokens.Shadow.mdY)
        .accessibilityIdentifier("compose-assistant-bar")
        .task {
            model.refreshAccess()
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedInput = .bar
            await assistant.refreshConnection()
            model.refreshAccess()
        }
        .onChange(of: assistant.connection.connectionRevision) {
            Task { await assistant.refreshConnection(); model.refreshAccess() }
        }
        .onChange(of: model.isRunning) { wasRunning, isRunning in
            if wasRunning, !isRunning, !model.messages.isEmpty { showsConversation = true }
        }
        .onChange(of: model.proposal?.id) { _, proposal in
            if proposal != nil { showsConversation = true }
        }
        .onChange(of: showsSettings) { _, isPresented in
            if !isPresented { model.refreshAccess(); focusedInput = showsConversation ? .conversation : .bar }
        }
        .sheet(isPresented: $showsSettings) { AssistantSettingsView(model: assistant, isSheet: true) }
        .onKeyPress(.escape) {
            guard model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !hasMarkedText else { return .ignored }
            if showsConversation { showsConversation = false }
            else { onClose() }
            return .handled
        }
    }

    private var conversationTitle: String {
        if model.availabilityMessage != nil { return "Set Up" }
        if model.errorMessage != nil { return "Review Error" }
        if model.isRunning { return model.statusText ?? "Thinking…" }
        if model.proposal != nil { return "Review Draft" }
        return "Conversation"
    }

    private var conversationSymbol: String {
        if model.errorMessage != nil { return "exclamationmark.circle" }
        if model.proposal != nil { return "doc.text" }
        return "bubble.left"
    }

    private func requestField(_ location: Input) -> some View {
        TextField(model.messages.isEmpty ? "Ask AI to write or plan a reply…" : "Ask for a change…",
                  text: $model.prompt, axis: .vertical)
            .textFieldStyle(.plain).font(.body).lineLimit(1...3)
            .focused($focusedInput, equals: location)
            .onKeyPress(.return, phases: .down) { press in
                guard !hasMarkedText else { return .ignored }
                if press.modifiers.contains(.shift) {
                    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                }
                guard !press.modifiers.contains(.option), !press.modifiers.contains(.control) else { return .ignored }
                submit()
                return .handled
            }
            .accessibilityLabel("Request to compose assistant")
            .accessibilityHint("Return to ask the assistant. Shift-Return for a new line.")
            .disabled(model.availabilityMessage != nil)
    }

    @ViewBuilder private var requestButton: some View {
        if model.isRunning {
            Button { model.stop() } label: {
                Image(systemName: "stop.fill").frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
            }
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            .help("Stop response").accessibilityLabel("Stop response")
        } else if model.availabilityMessage != nil {
            Button("Set Up") { showsConversation = false; showsSettings = true }
                .controlSize(.small)
                .accessibilityLabel("Set up compose assistant")
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up").font(.body.weight(.semibold))
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
            .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Ask assistant (Return)").accessibilityLabel("Ask assistant")
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s2) {
                Label("Compose assistant", systemImage: "sparkles").font(.headline)
                Spacer(minLength: Tokens.Space.s2)
                Menu {
                    Button("New Chat", systemImage: "plus.bubble") { model.clear() }
                    Button("Assistant Settings…", systemImage: "slider.horizontal.3") {
                        showsConversation = false
                        showsSettings = true
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Assistant Options").accessibilityLabel("Assistant Options")
                iconButton("Close conversation", symbol: "xmark") { showsConversation = false }
            }
            .padding(Tokens.Space.s3)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                        if let message = model.availabilityMessage {
                            Text(message).font(.callout).textSelection(.enabled)
                            Button("Assistant Settings…") { showsConversation = false; showsSettings = true }
                        } else if model.messages.isEmpty {
                            Text("Ask for a reply, a shorter version, or a time to meet. The assistant uses this draft, its conversation, and the mail and calendars you allow.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(message.isUser ? "You" : "Assistant")
                                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                if !message.text.isEmpty { AssistantMarkdownView(text: message.text) }
                                if message.state == .streaming {
                                    HStack(spacing: Tokens.Space.s2) {
                                        ProgressView().controlSize(.small)
                                        Text(model.statusText ?? "Thinking…").font(.caption).foregroundStyle(.secondary)
                                    }
                                } else if message.state == .cancelled {
                                    Text("Response stopped").font(.caption).foregroundStyle(.secondary)
                                }
                                if !message.sources.isEmpty {
                                    DisclosureGroup("Sources") {
                                        ForEach(message.sources) { source in
                                            Label(source.title.isEmpty ? "No Subject" : source.title,
                                                  systemImage: source.systemImage)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !model.isRunning, let status = model.statusText {
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                        if let error = model.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(Tokens.Status.error)
                                .textSelection(.enabled)
                            Button("Try Again") { model.retry() }.disabled(model.isRunning)
                        }
                        if let proposal = model.proposal {
                            Divider()
                            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                                Text("Suggested draft").font(.headline)
                                Text(proposal.subject).font(.callout.weight(.medium))
                                Text(proposal.body).font(.body).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if model.preservesInlineImages {
                                    Text("Inline images will stay below the rewritten text.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let message = model.proposalStatusMessage {
                                    Label(message, systemImage: "info.circle")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("compose-assistant-preview")
                        }
                        Color.clear.frame(height: Tokens.Space.s1).id("compose-assistant-end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.s4)
                }
                .frame(height: Tokens.Popover.maxListHeight)
                .onChange(of: model.messages.count) { proxy.scrollTo("compose-assistant-end", anchor: .bottom) }
                .onChange(of: model.proposal?.id) { proxy.scrollTo("compose-assistant-end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("compose-assistant-end", anchor: .bottom) }
            }
            if model.proposal != nil || model.canUndo {
                Divider()
                HStack(spacing: Tokens.Space.s2) {
                    Text("Review before sending.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: Tokens.Space.s2)
                    if model.canUndo { Button("Undo") { model.undo() }.help("Undo the assistant's changes") }
                    if model.proposal != nil {
                        Button("Apply to Draft") { model.apply() }
                            .buttonStyle(.borderedProminent).disabled(!model.canApply)
                            .accessibilityIdentifier("compose-assistant-apply")
                    }
                }
                .padding(Tokens.Space.s3)
            }
            Divider()
            HStack(alignment: .bottom, spacing: Tokens.Space.s2) {
                requestField(.conversation)
                requestButton
            }
            .padding(Tokens.Space.s3)
        }
        .frame(width: Tokens.Sheet.smallWidth)
        .background(Tokens.Surface.primary)
        .onAppear { focusedInput = .conversation }
        .onDisappear { focusedInput = .bar }
    }

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func submit() {
        guard !model.isRunning, model.availabilityMessage == nil,
              !model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.send()
        if model.errorMessage != nil { showsConversation = true }
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}
