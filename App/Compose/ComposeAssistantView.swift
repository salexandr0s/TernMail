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
    @State private var focusedInput: Input?
    @State private var choosesContextFiles = false
    @State private var barDropTargeted = false
    @State private var conversationDropTargeted = false
    @State private var barInputDropTargeted = false
    @State private var conversationInputDropTargeted = false

    private enum Input: Hashable { case bar, conversation }

    var body: some View {
        VStack(spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s2) {
                Label {
                    Text("Ask AI").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                }
                .font(.callout.weight(.semibold)).fixedSize()
                Text(barHasFileDrop ? "Use as AI context" : compactContext)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(model.contextDescription)
                    .accessibilityLabel(loadingCaption ?? "Context: \(model.contextDescription)")
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                Button {
                    showsConversation.toggle()
                } label: {
                    ViewThatFits(in: .horizontal) {
                        if model.proposal != nil || model.errorMessage != nil || model.hasContextFileErrors
                            || (model.availabilityMessage != nil && loadingCaption == nil) {
                            Label(conversationTitle, systemImage: conversationSymbol).fixedSize()
                        }
                        Image(systemName: conversationSymbol)
                            .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    }
                }
                .buttonStyle(.borderless).controlSize(.small)
                .foregroundStyle(model.proposal != nil ? Color.accentColor : Color.secondary)
                .help(conversationTitle)
                .accessibilityLabel(conversationTitle)
                .popover(isPresented: $showsConversation, arrowEdge: .top) { conversation }
                iconButton("Assistant Settings", symbol: "slider.horizontal.3") { showsSettings = true }
                iconButton("Close compose assistant", symbol: "xmark", action: onClose)
            }
            contextFiles
            HStack(alignment: .bottom, spacing: Tokens.Space.s2) {
                contextFileButton
                requestField(.bar)
                    .frame(minWidth: 0, maxWidth: .infinity)
                requestButton
            }
        }
        .padding(Tokens.Space.s3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .ternOutline(radius: Tokens.Radius.lg)
        .overlay { dropOutline(isTargeted: barHasFileDrop) }
        .ternAnimation(value: model.contextAttachments.isEmpty)
        .shadow(color: Tokens.Shadow.mdColor, radius: Tokens.Shadow.mdRadius, y: Tokens.Shadow.mdY)
        .accessibilityIdentifier("compose-assistant-bar")
        .composeFileDrop(isEnabled: true, isTargeted: $barDropTargeted, onDrop: acceptContextFiles)
        .fileImporter(isPresented: $choosesContextFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { acceptContextFiles(urls.map { ComposeDroppedFile(url: $0) }) }
        }
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
        .onChange(of: model.hasContextFileErrors) { _, hasErrors in
            if hasErrors { showsConversation = true }
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
        if model.hasContextFileErrors { return "Review Files" }
        if loadingCaption != nil { return "Conversation" }
        if model.availabilityMessage != nil { return "Set Up" }
        if model.errorMessage != nil { return "Review Error" }
        if model.proposal != nil { return "Review Draft" }
        return "Conversation"
    }

    private var compactContext: String {
        if model.isRunning { return model.statusText ?? "Thinking…" }
        if model.isLoadingContextFiles { return "Reading AI context…" }
        if model.hasContextFileErrors { return "File needs attention" }
        if let loadingCaption { return loadingCaption }
        if model.availabilityMessage != nil { return "Setup needed" }
        if model.errorMessage != nil { return "Couldn't finish" }
        if let status = model.statusText { return status }
        return assistant.hasCalendarAccess ? "Draft · Mail · Calendar" : "Draft · Mail"
    }

    private var loadingCaption: String? {
        if assistant.connection.isRestoring { return "Loading ChatGPT…" }
        if assistant.isLoadingModels, model.availabilityMessage == AssistantError.noModel.errorDescription {
            return "Loading models…"
        }
        return nil
    }

    private var conversationSymbol: String {
        if model.errorMessage != nil || model.hasContextFileErrors { return "exclamationmark.circle" }
        if model.proposal != nil { return "doc.text" }
        return "bubble.left"
    }

    private func requestField(_ location: Input) -> some View {
        ComposePromptField(text: $model.prompt, isFocused: Binding(
            get: { focusedInput == location },
            set: { focused in
                if focused { focusedInput = location }
                else if focusedInput == location { focusedInput = nil }
            }), isFileTargeted: location == .bar ? $barInputDropTargeted : $conversationInputDropTargeted,
            placeholder: model.messages.isEmpty ? "Write a reply, or suggest a time to meet…" : "Ask for a change…",
            isEditable: model.availabilityMessage == nil, canAddFiles: model.canAddContextFiles,
            onDrop: acceptContextFiles, onRejectedDrop: model.rejectContextFileDrop,
            onSubmit: submit, onEscape: {
                if showsConversation { showsConversation = false }
                else { onClose() }
            }, onUnsupportedFilePaste: {
                model.rejectContextFilePaste()
                showsConversation = true
            })
    }

    @ViewBuilder private var requestButton: some View {
        if model.isRunning {
            Button { model.stop() } label: {
                Image(systemName: "stop.fill").frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
            }
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            .help("Stop response").accessibilityLabel("Stop response")
        } else if model.isLoadingContextFiles {
            ProgressView().controlSize(.small)
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .accessibilityLabel("Reading AI context files")
        } else if let loadingCaption {
            ProgressView().controlSize(.small)
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .accessibilityLabel(loadingCaption)
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
            .disabled(!model.canAsk || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Ask assistant (Return)").accessibilityLabel("Ask assistant")
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s2) {
                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                    Label("Ask AI", systemImage: "sparkles").font(.headline)
                    Text(conversationHasFileDrop ? "Use as AI context"
                         : (assistant.hasCalendarAccess ? "Mail and calendar context" : "Mail context"))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(model.contextDescription)
                }
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
                        if let loadingCaption {
                            HStack(spacing: Tokens.Space.s2) {
                                ProgressView().controlSize(.small)
                                Text(loadingCaption).font(.callout)
                            }
                        } else if let message = model.availabilityMessage {
                            Text(message).font(.callout).textSelection(.enabled)
                            Button("Assistant Settings…") { showsConversation = false; showsSettings = true }
                        } else if model.messages.isEmpty {
                            starters
                        }
                        contextFileErrors
                        ForEach(model.messages) { message in
                            messageRow(message)
                        }
                        if !model.isRunning, let status = model.statusText {
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                        if let error = model.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(Tokens.Status.error)
                                .textSelection(.enabled)
                            Button("Try Again") { model.retry() }.disabled(!model.canAsk)
                        }
                        if let proposal = model.proposal {
                            draftPreview(proposal)
                        }
                        Color.clear.frame(height: Tokens.Space.s1).id("compose-assistant-end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.s4)
                }
                .frame(height: Tokens.Popover.maxListHeight)
                .onChange(of: model.messages.count) { proxy.scrollTo("compose-assistant-end", anchor: .bottom) }
                .onChange(of: model.proposal?.id) { scrollToResult(proxy) }
                .onChange(of: model.hasContextFileErrors) { scrollToResult(proxy) }
                .onAppear { scrollToResult(proxy) }
            }
            if model.proposal != nil || model.canUndo {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: Tokens.Space.s2) {
                        Text(model.proposal == nil ? "Draft updated" : "Review before sending")
                            .font(.caption).foregroundStyle(.secondary)
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
                .ternTransition(.disclosure)
            }
            Divider()
            VStack(spacing: Tokens.Space.s2) {
                contextFiles
                HStack(alignment: .bottom, spacing: Tokens.Space.s2) {
                    contextFileButton
                    requestField(.conversation)
                    requestButton
                }
            }
            .padding(Tokens.Space.s3)
            .ternAnimation(value: model.contextAttachments.isEmpty)
        }
        .frame(width: Tokens.Sheet.smallWidth)
        .background(Tokens.Surface.muted)
        .overlay { dropOutline(isTargeted: conversationHasFileDrop) }
        .ternAnimation(value: model.proposal != nil || model.canUndo)
        .composeFileDrop(isEnabled: true, isTargeted: $conversationDropTargeted, onDrop: acceptContextFiles)
        .onAppear { focusedInput = .conversation }
        .onDisappear { focusedInput = .bar }
    }

    private var barHasFileDrop: Bool { barDropTargeted || barInputDropTargeted }
    private var conversationHasFileDrop: Bool { conversationDropTargeted || conversationInputDropTargeted }

    private var contextFileButton: some View {
        iconButton("Add files as AI context only", symbol: "paperclip") {
            showsConversation = false
            choosesContextFiles = true
        }
        .disabled(!model.canAddContextFiles)
    }

    @ViewBuilder private var contextFiles: some View {
        if !model.contextAttachments.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("AI context · Not sent with email")
                    .font(.caption2).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: Tokens.Space.s2) {
                        ForEach(model.contextAttachments) { file in
                            HStack(spacing: Tokens.Space.s2) {
                                if file.isLoading { ProgressView().controlSize(.mini) }
                                else {
                                    Image(systemName: file.errorMessage == nil ? "doc" : "exclamationmark.circle")
                                        .foregroundStyle(file.errorMessage == nil ? Color.secondary : Tokens.Status.error)
                                }
                                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                                    Text(file.filename).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(file.statusText).font(.caption2).lineLimit(1)
                                        .foregroundStyle(file.errorMessage == nil ? Color.secondary : Tokens.Status.error)
                                }
                                .frame(maxWidth: Tokens.Layout.attachmentWidth, alignment: .leading)
                                .help(file.filename + "\n" + file.statusText)
                                if file.errorMessage != nil {
                                    iconButton("Retry reading \(file.filename)", symbol: "arrow.clockwise") {
                                        model.retryContextFile(file.id)
                                    }
                                    .disabled(!model.canAddContextFiles)
                                }
                                iconButton("Remove \(file.filename) from AI context", symbol: "xmark.circle.fill") {
                                    model.removeContextFile(file.id)
                                }
                            }
                            .padding(.horizontal, Tokens.Space.s2).padding(.vertical, Tokens.Space.s1)
                            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                            .ternOutline(radius: Tokens.Radius.md)
                            .ternTransition(.disclosure)
                        }
                    }
                    .ternAnimation(value: model.contextAttachments.map(\.id))
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ternTransition(.disclosure)
        }
    }

    private func dropOutline(isTargeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.lg)
            .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: Tokens.Border.focus)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var contextFileErrors: some View {
        if model.hasContextFileErrors {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                ForEach(model.contextAttachments) { file in
                    if let error = file.errorMessage {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Label(file.filename, systemImage: "exclamationmark.circle")
                                .font(.callout.weight(.medium))
                            Text(error).font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: Tokens.Space.s2) {
                                Button("Retry") { model.retryContextFile(file.id) }.disabled(!model.canAddContextFiles)
                                Button("Remove") { model.removeContextFile(file.id) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .id("compose-context-errors")
        }
    }

    private func acceptContextFiles(_ files: [ComposeDroppedFile]) {
        barDropTargeted = false; conversationDropTargeted = false
        barInputDropTargeted = false; conversationInputDropTargeted = false
        model.addContextFiles(files)
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Start with your draft").font(.headline)
            Text("Use this conversation and the mail and calendars you've allowed.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: Tokens.Space.s2) {
                starter("Draft a reply", symbol: "arrowshape.turn.up.left",
                        prompt: "Draft a reply based on this conversation.")
                starter("Make it shorter", symbol: "text.alignleft",
                        prompt: "Make my current draft shorter while keeping the important details.")
                starter("Suggest a time", symbol: "calendar",
                        prompt: "Suggest a time to meet next week. Check my calendar first.")
            }
        }
    }

    private func starter(_ title: String, symbol: String, prompt: String) -> some View {
        Button {
            model.prompt = prompt
            focusedInput = .conversation
        } label: {
            HStack(spacing: Tokens.Space.s2) {
                Label(title, systemImage: symbol)
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.left").font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout).padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .ternOutline(radius: Tokens.Radius.md)
        }
        .buttonStyle(.borderless).foregroundStyle(.primary)
        .help("Add this request to the assistant input")
    }

    @ViewBuilder private func messageRow(_ message: AssistantMessage) -> some View {
        if message.isUser {
            VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                Text("You").font(.caption).foregroundStyle(.secondary)
                Text(message.text).font(.callout).textSelection(.enabled)
                    .padding(Tokens.Space.s3)
                    .background(Tokens.Assistant.userBubble, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, Tokens.Space.s6)
        } else {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("Assistant").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if !message.text.isEmpty { AssistantMarkdownView(markdown: message.markdown) }
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
                            Label(source.title.isEmpty ? "No Subject" : source.title, systemImage: source.systemImage)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func draftPreview(_ proposal: ComposeAssistantProposal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Draft preview", systemImage: "doc.text")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, Tokens.Space.s4).padding(.vertical, Tokens.Space.s3)
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Subject").font(.caption).foregroundStyle(.secondary)
                    Text(proposal.subject).font(.callout.weight(.medium)).textSelection(.enabled)
                }
                Divider()
                Text(proposal.body).font(.body).lineSpacing(Tokens.Space.s0_5).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if model.preservesInlineImages {
                    Text("Inline images will stay below the rewritten text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.proposalStatusMessage {
                    Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(Tokens.Space.s4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md)
        .accessibilityIdentifier("compose-assistant-preview")
        .id("compose-assistant-proposal")
    }

    private func scrollToResult(_ proxy: ScrollViewProxy) {
        if model.hasContextFileErrors { proxy.scrollTo("compose-context-errors", anchor: .top) }
        else if model.proposal != nil { proxy.scrollTo("compose-assistant-proposal", anchor: .top) }
        else { proxy.scrollTo("compose-assistant-end", anchor: .bottom) }
    }

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func submit() {
        guard model.canAsk,
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
