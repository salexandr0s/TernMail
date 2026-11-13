import AppKit
import SwiftUI

struct AssistantMessageView: View, Equatable {
    let message: AssistantMessage
    let startsGroup: Bool
    let status: String?
    let canRetry: Bool
    let onRetry: () -> Void
    let onOpenSource: (AssistantSource) -> Void
    let onOpenSourceInNewWindow: (AssistantSource) -> Void
    let onOpenDraft: (String) -> Void
    let model: AssistantModel?
    /// What `==` reads of the message. The message holds a class, so `==`
    /// cannot read it outside the main actor.
    private let version: Version
    @State private var showsAllEmails = false
    @State private var showsSources = false
    @State private var copied = false

    private struct Version: Equatable, Sendable {
        let id: UUID
        let revision: Int
        let isStreaming: Bool
    }

    init(message: AssistantMessage, startsGroup: Bool, status: String?, canRetry: Bool,
         onRetry: @escaping () -> Void, onOpenSource: @escaping (AssistantSource) -> Void,
         onOpenSourceInNewWindow: @escaping (AssistantSource) -> Void,
         onOpenDraft: @escaping (String) -> Void, model: AssistantModel? = nil) {
        self.message = message; self.startsGroup = startsGroup; self.status = status; self.canRetry = canRetry
        self.onRetry = onRetry; self.onOpenSource = onOpenSource
        self.onOpenSourceInNewWindow = onOpenSourceInNewWindow; self.onOpenDraft = onOpenDraft; self.model = model
        version = Version(id: message.id, revision: message.revision, isStreaming: message.state == .streaming)
    }

    /// A row is redrawn when its own message was edited, not when another reply
    /// streams. Only a streaming reply shows the status. The actions and the
    /// model are not compared: a row's actions reach the same objects for as
    /// long as the row exists.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.startsGroup == rhs.startsGroup && lhs.canRetry == rhs.canRetry
            && (!lhs.version.isStreaming || lhs.status == rhs.status)
    }

    var body: some View {
        let emails = uniqueEmails, sources = uniqueSources
        HStack(alignment: .top, spacing: 0) {
            if message.isUser { Spacer(minLength: Tokens.Assistant.bubbleInset) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: Tokens.Space.s2) {
                bubble(emails: emails)
                footer(sources: sources)
                if showsSources, !sources.isEmpty {
                    sourceList(sources).ternTransition(.disclosure)
                }
            }
            .ternAnimation(value: showsSources, duration: Tokens.Motion.slow)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(message.isUser ? "Your message" : "Assistant response")
            .accessibilityHint(messageDate)
            .contextMenu { messageMenu }
            .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        }
        .padding(.top, startsGroup ? Tokens.Space.s4 : Tokens.Space.s1_5)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }

    private func bubble(emails: [AssistantEmailResult]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.AssistantFormatting.blockGap) {
            if !message.text.isEmpty {
                if message.isUser {
                    Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(Tokens.Space.s0_5)
                        .accessibilityLabel("You: \(message.text)")
                        .help(messageDate)
                } else {
                    AssistantMarkdownView(markdown: message.markdown)
                        .help(messageDate)
                }
            }
            if message.state == .streaming {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.mini)
                    Text(status ?? "Thinking…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, Tokens.Space.s1)
                .accessibilityElement(children: .combine)
            }
            if let model, !message.taskResults.isEmpty || !message.eventResults.isEmpty {
                AssistantResultCards(message: message, model: model, onOpenSource: onOpenSource)
            }
            if !emails.isEmpty {
                VStack(spacing: Tokens.Space.s2) {
                    HStack {
                        Label("Related mail", systemImage: "envelope")
                        Spacer(minLength: Tokens.Space.s2)
                        Text("\(emails.count)").monospacedDigit()
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(showsAllEmails ? emails : Array(emails.prefix(Tokens.AssistantFormatting.resultPreviewCount))) { email in
                        AssistantEmailCard(email: email, onOpen: onOpenSource, onOpenInNewWindow: onOpenSourceInNewWindow)
                            .ternTransition(.disclosure)
                    }
                    if emails.count > Tokens.AssistantFormatting.resultPreviewCount {
                        Button {
                            showsAllEmails.toggle()
                        } label: {
                            Text(showsAllEmails ? "Show fewer emails" : "Show all \(emails.count) emails")
                                .frame(minHeight: Tokens.Space.s6)
                                .contentShape(Rectangle())
                        }
                        .font(.caption.weight(.medium)).buttonStyle(.borderless)
                        .accessibilityValue(showsAllEmails ? "Expanded" : "Collapsed")
                    }
                }
                .ternAnimation(value: showsAllEmails, duration: Tokens.Motion.slow)
            }
            ForEach(message.draftIDs, id: \.self) { draftID in
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Button { onOpenDraft(draftID) } label: {
                        HStack(spacing: Tokens.Space.s2) {
                            Label("Review Draft", systemImage: "square.and.pencil")
                            Spacer(minLength: Tokens.Space.s2)
                            Image(systemName: "arrow.up.right").font(.caption).accessibilityHidden(true)
                        }
                        .font(.callout.weight(.medium))
                        .padding(Tokens.AssistantFormatting.inset)
                        .background(Tokens.Assistant.userBubble, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                        .ternOutline(radius: Tokens.Radius.md, style: .contrastOnly)
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    }
                    .buttonStyle(.borderless)
                    .help("Open the editable draft in Tern")
                    if let note = message.draftStyleNotes[draftID] {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let error = message.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(Tokens.AssistantFormatting.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .ternOutline(radius: Tokens.Radius.md, style: .contrastOnly)
            }
        }
        .padding(.horizontal, message.isUser ? Tokens.Space.s4 : 0)
        .padding(.vertical, message.isUser ? Tokens.Space.s3 : 0)
        .foregroundStyle(.primary)
        .background(message.isUser ? Color.accentColor.opacity(Tokens.Opacity.wash) : .clear,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay {
            if message.isUser {
                Color.clear.ternOutline(radius: Tokens.Radius.lg)
                    .allowsHitTesting(false)
            }
        }
    }

    private func footer(sources: [AssistantSource]) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            if message.state == .cancelled { Text("Stopped") }
            if message.state == .failed { Label("Incomplete", systemImage: "exclamationmark.circle") }
            if !sources.isEmpty {
                Button { showsSources.toggle() } label: {
                    Label("\(sources.count) \(sources.count == 1 ? "source" : "sources")",
                          systemImage: showsSources ? "chevron.up" : "text.book.closed")
                        .padding(.horizontal, Tokens.Space.s1_5)
                        .frame(minHeight: Tokens.Space.s6)
                        .background(showsSources ? Color.accentColor.opacity(Tokens.Opacity.wash) : .clear,
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                .buttonStyle(.plain).controlSize(.small)
                .ternHover()
                .accessibilityValue(showsSources ? "Expanded" : "Collapsed")
                .help(showsSources ? "Hide sources" : "Show sources")
            }
            if hasCopyText {
                Button { copy(.formatted) } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                .buttonStyle(.plain)
                .ternHover()
                .help(copied ? "Copied" : (message.isUser ? "Copy message" : "Copy response"))
                .accessibilityLabel(copied ? "Copied" : (message.isUser ? "Copy message" : "Copy response"))
                .onChange(of: message.text) { copied = false }
            }
            if canRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                .buttonStyle(.plain)
                .ternHover()
                .help("Retry").accessibilityLabel("Retry")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, message.isUser ? Tokens.Space.s2 : 0)
    }

    private func sourceList(_ sources: [AssistantSource]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            ForEach(sources) { source in
                let title = sourceTitle(source)
                Button { onOpenSource(source) } label: {
                    Label(title, systemImage: source.systemImage)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(minHeight: Tokens.Space.s6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .font(Tokens.AssistantFormatting.metadataFont).buttonStyle(.link).help(title)
                .accessibilityLabel("Open source: \(title)")
            }
        }
        .padding(Tokens.AssistantFormatting.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
        .ternOutline(radius: Tokens.AssistantFormatting.cornerRadius)
    }

    @ViewBuilder private var messageMenu: some View {
        Group {
            if hasCopyText {
                Button("Copy", systemImage: "doc.on.doc") { copy(.formatted) }
                if !message.isUser {
                    Button("Copy as Markdown") { copy(.markdown) }
                    Button("Copy as Plain Text") { copy(.plainText) }
                }
            }
            if canRetry {
                if hasCopyText { Divider() }
                Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private func copy(_ format: AssistantMarkdown.CopyFormat) {
        // User messages show as typed, never as Markdown, so they copy unchanged.
        AssistantMarkdown.copy(AssistantResultExport.markdown(message), as: message.isUser ? .markdown : format)
        copied = true
    }

    /// The export is built when the reader copies, not to decide whether to
    /// offer the copy action.
    private var hasCopyText: Bool {
        AssistantResultExport.hasContent(message)
    }

    private var messageDate: String {
        message.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var uniqueEmails: [AssistantEmailResult] {
        var seen = Set<String>()
        return message.emailResults.filter { seen.insert($0.id).inserted }
    }

    private var uniqueSources: [AssistantSource] {
        var seen = Set<String>()
        return message.sources.filter { source in
            if source.isCalendar { return seen.insert(source.id).inserted }
            let key = AssistantSource(accountID: source.accountID, threadID: source.threadID,
                                      messageID: source.partID == nil ? nil : source.messageID,
                                      partID: source.partID, title: source.title).id
            return seen.insert(key).inserted
        }
    }

    private func sourceTitle(_ source: AssistantSource) -> String {
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "No Subject" : title
    }
}
