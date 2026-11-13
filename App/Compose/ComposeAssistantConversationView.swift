import SwiftUI

/// The transcript in the compose assistant's popover. It is the only view
/// that reads the messages, so a streamed reply redraws it and leaves the bar
/// and the rest of the popover alone.
struct ComposeAssistantConversationView: View {
    private static let scrollSpace = "compose-assistant-scroll"
    private static let endID = "compose-assistant-end"

    let model: ComposeAssistantModel
    /// Shown while the provider or its models load.
    let loadingCaption: String?
    let availabilityMessage: String?
    let onOpenSettings: () -> Void
    /// Puts a starter request in the input.
    let onUseStarter: (String) -> Void
    @State private var scrollTracking = AssistantScrollTracking()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcript
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.s4)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: ComposeAssistantScrollFrameKey.self,
                                                   value: content.frame(in: .named(Self.scrollSpace)))
                        }
                    }
            }
            .coordinateSpace(.named(Self.scrollSpace))
            .frame(height: Tokens.Popover.maxListHeight)
            .onPreferenceChange(ComposeAssistantScrollFrameKey.self) { frame in
                scrollTracking.update(frame: frame, viewportHeight: Tokens.Popover.maxListHeight)
            }
            .onChange(of: model.messages.count) {
                scrollTracking.followLatest()
                proxy.scrollTo(Self.endID, anchor: .bottom)
            }
            .onChange(of: streamedContent) { followStream(proxy) }
            .onChange(of: model.proposal?.id) { scrollToResult(proxy) }
            .onChange(of: model.hasContextFileErrors) { scrollToResult(proxy) }
            .onAppear { scrollToResult(proxy) }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            if let loadingCaption {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(loadingCaption).font(.callout)
                }
            } else if let availabilityMessage {
                Text(availabilityMessage).font(.callout).textSelection(.enabled)
                Button("Assistant Settings…", action: onOpenSettings)
            } else if model.messages.isEmpty {
                starters
            }
            contextFileErrors
            ForEach(model.messages) { message in
                ComposeAssistantMessageRow(message: message,
                                           status: message.state == .streaming ? model.statusText : nil)
                    .equatable()
            }
            if !model.isRunning, let status = model.statusText {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Tokens.Status.error)
                    .textSelection(.enabled)
                Button("Try Again") { model.retry() }
                    .disabled(!model.canAsk(availabilityMessage: availabilityMessage))
            }
            if let proposal = model.proposal {
                draftPreview(proposal)
            }
            Color.clear.frame(height: Tokens.Space.s1).id(Self.endID)
        }
    }

    /// Changes with each flush of a streamed reply.
    private var streamedContent: ComposeAssistantStreamedContent {
        ComposeAssistantStreamedContent(revision: model.messages.last?.revision, status: model.statusText)
    }

    /// Keeps the end of a streamed reply in view until the reader scrolls up.
    /// A suggestion or a file error is the thing to read, so it keeps its place.
    private func followStream(_ proxy: ScrollViewProxy) {
        guard scrollTracking.followsLatest, model.proposal == nil, !model.hasContextFileErrors else { return }
        // The reply's new text is laid out after this update.
        Task { @MainActor in
            await Task.yield()
            guard scrollTracking.followsLatest else { return }
            proxy.scrollTo(Self.endID, anchor: .bottom)
        }
    }

    private func scrollToResult(_ proxy: ScrollViewProxy) {
        if model.hasContextFileErrors { proxy.scrollTo("compose-context-errors", anchor: .top) }
        else if model.proposal != nil { proxy.scrollTo("compose-assistant-proposal", anchor: .top) }
        else { proxy.scrollTo(Self.endID, anchor: .bottom) }
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
            onUseStarter(prompt)
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
}

/// One message of the transcript. A streamed flush changes one message, so
/// the rows of the others compare equal and are not redrawn.
private struct ComposeAssistantMessageRow: View, Equatable {
    let message: AssistantMessage
    /// What the assistant is doing, for a reply that is still streaming.
    let status: String?
    /// What `==` reads of the message. The message holds a class, so `==`
    /// cannot read it outside the main actor.
    private let version: Version

    private struct Version: Equatable, Sendable {
        let id: UUID
        let revision: Int
    }

    init(message: AssistantMessage, status: String?) {
        self.message = message
        self.status = status
        version = Version(id: message.id, revision: message.revision)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.status == rhs.status
    }

    var body: some View {
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
                        Text(status ?? "Thinking…").font(.caption).foregroundStyle(.secondary)
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
}

/// One comparison covers the text and the status of a streamed reply.
private struct ComposeAssistantStreamedContent: Equatable {
    let revision: Int?
    let status: String?
}

private struct ComposeAssistantScrollFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
