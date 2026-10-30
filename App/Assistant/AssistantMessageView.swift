import AppKit
import SwiftUI

struct AssistantMessageView: View {
    let message: AssistantMessage
    let startsGroup: Bool
    let status: String?
    let canRetry: Bool
    let onRetry: () -> Void
    let onOpenSource: (AssistantSource) -> Void
    let onOpenDraft: (String) -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsAllEmails = false
    @State private var showsSources = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.isUser { Spacer(minLength: Tokens.Assistant.bubbleInset) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: Tokens.Space.s2) {
                if startsGroup {
                    HStack(spacing: Tokens.Space.s2) {
                        if !message.isUser {
                            ChatGPTBrand(size: Tokens.Space.s4).accessibilityHidden(true)
                        }
                        Text(message.isUser ? "You" : "Assistant")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(message.isUser ? .secondary : .primary)
                    }
                    .padding(.horizontal, message.isUser ? Tokens.Space.s3 : 0)
                }
                bubble
                footer
            }
            .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        }
        .padding(.top, startsGroup ? Tokens.Space.s4 : 0)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            if !message.text.isEmpty {
                if message.isUser {
                    Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else {
                    AssistantMarkdownView(text: message.text)
                }
            }
            if message.state == .streaming {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.mini)
                    Text(status ?? "Thinking…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.vertical, Tokens.Space.s2)
                .background(Tokens.Surface.canvas, in: Capsule())
                .accessibilityElement(children: .combine)
            }
            if !emails.isEmpty {
                VStack(spacing: Tokens.Space.s2) {
                    ForEach(showsAllEmails ? emails : Array(emails.prefix(3))) { email in
                        AssistantEmailCard(email: email, onOpen: onOpenSource)
                    }
                    if emails.count > 3 {
                        Button(showsAllEmails ? "Show fewer emails" : "Show \(emails.count - 3) more emails") {
                            showsAllEmails.toggle()
                        }
                        .font(.caption.weight(.medium)).buttonStyle(.borderless)
                        .padding(.vertical, Tokens.Space.s1)
                    }
                }
            }
            ForEach(message.draftIDs, id: \.self) { draftID in
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Button { onOpenDraft(draftID) } label: {
                        HStack(spacing: Tokens.Space.s2) {
                            Label("Review draft", systemImage: "square.and.pencil")
                            Spacer(minLength: Tokens.Space.s2)
                            Image(systemName: "arrow.up.right").font(.caption).accessibilityHidden(true)
                        }
                        .font(.callout.weight(.medium))
                        .padding(Tokens.Space.s3)
                        .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                        .overlay {
                            if contrast == .increased {
                                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                                    .strokeBorder(Color.primary, lineWidth: Tokens.Border.hairline)
                                    .allowsHitTesting(false)
                            }
                        }
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
            if !sources.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showsSources) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        ForEach(sources) { source in
                            let title = sourceTitle(source)
                            Button { onOpenSource(source) } label: {
                                Label(title, systemImage: source.systemImage)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.link).help(title)
                            .accessibilityLabel("Open source: \(title)")
                        }
                    }
                    .padding(.top, Tokens.Space.s2)
                } label: {
                    Label("\(sources.count) \(sources.count == 1 ? "source" : "sources")", systemImage: "link")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if let error = message.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(Tokens.Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .overlay {
                        if contrast == .increased {
                            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                                .strokeBorder(Color.primary, lineWidth: Tokens.Border.hairline)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .padding(message.isUser ? Tokens.Space.s3 : 0)
        .foregroundStyle(.primary)
        .background(message.isUser ? bubbleColor : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay {
            if message.isUser, contrast == .increased {
                RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                    .strokeBorder(Color.primary, lineWidth: Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.s2) {
            Text(message.createdAt, format: .dateTime.hour().minute())
                .help(message.createdAt.formatted(date: .abbreviated, time: .shortened))
            if message.state == .cancelled { Text("Stopped") }
            if message.state == .failed { Label("Incomplete", systemImage: "exclamationmark.circle") }
            if !message.text.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                .buttonStyle(.borderless)
                .help(copied ? "Copied" : (message.isUser ? "Copy message" : "Copy response"))
                .accessibilityLabel(copied ? "Copied" : (message.isUser ? "Copy message" : "Copy response"))
                .onChange(of: message.text) { copied = false }
            }
            if canRetry {
                Button("Try again", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, message.isUser ? Tokens.Space.s3 : 0)
    }

    private var bubbleColor: Color {
        if message.isUser, contrast != .increased { return Tokens.Assistant.userBubble }
        return Tokens.Assistant.assistantBubble
    }

    private var emails: [AssistantEmailResult] {
        var seen = Set<String>()
        return message.emailResults.filter { seen.insert($0.id).inserted }
    }

    private var sources: [AssistantSource] {
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
