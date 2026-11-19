import SwiftUI
import SyncEngine

/// Supplement disclosure and sheets stay attached to this draft while their viewport scrolls.
struct ComposeSupplements: View {
    @Bindable var model: ComposeModel
    let assistant: AssistantModel
    let composeAssistant: ComposeAssistantModel?
    let showsAssistant: Bool
    let onCloseAssistant: () -> Void
    @State private var showsQuote = false
    @State private var editsQuote = false
    @State private var editsSignature = false

    var body: some View {
        VStack(spacing: 0) {
            if showsAssistant, let composeAssistant {
                ComposeAssistantView(model: composeAssistant, assistant: assistant) {
                    onCloseAssistant()
                }
                .frame(maxWidth: Tokens.Compose.assistantMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(Tokens.Space.s3)
                .ternTransition(.disclosure)
            }
            if showsAttachments {
                AttachmentStrip(
                    attachments: model.attachments.filter { $0.contentID == nil },
                    failed: model.failedAttachments,
                    isEditable: model.isEditable,
                    fileURL: { [model] in await model.attachmentFileURL($0) },
                    retry: { model.retry($0) },
                    dismissFailure: { model.dismissFailure($0) }
                ) {
                    model.removeAttachment($0)
                }
                .ternTransition(.disclosure)
            }
            if model.content.signatureAboveQuote { signature }
            if model.awaitsOriginal {
                originalStatus
            } else if let quote = model.draft?.quotedPlainText, !quote.isEmpty {
                quotedText(quote)
            }
            if !model.content.signatureAboveQuote { signature }
        }
        .ternAnimation(value: showsAssistant, duration: Tokens.Motion.slow)
        .ternAnimation(value: showsAttachments)
        .sheet(isPresented: $editsQuote, onDismiss: { model.isEditingSupplement = false }) {
            ComposeQuoteEditor(text: model.draft?.quotedPlainText ?? "") { await model.replaceQuote(with: $0) }
        }
        .sheet(isPresented: $editsSignature, onDismiss: { model.isEditingSupplement = false }) {
            ComposeSignatureEditor(html: model.content.signatureHTML) { model.replaceSignature(with: $0) }
        }
    }

    private var showsAttachments: Bool {
        model.attachments.contains(where: { $0.contentID == nil }) || !model.failedAttachments.isEmpty
    }

    private var signature: some View {
        ComposeSignatureView(model: model) {
            model.isEditingSupplement = true
            editsSignature = true
        }
    }

    private func quotedText(_ quote: String) -> some View {
        let noun = model.draft?.kind == .forward ? "Forwarded Message" : "Quoted Text"
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                showsQuote.toggle()
            } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: Tokens.Space.s3)
                        .rotationEffect(.degrees(showsQuote ? 90 : 0))
                    Image(systemName: "text.quote")
                        .frame(width: Tokens.Control.icon)
                    Text(noun)
                        .font(.caption.weight(.medium))
                    Spacer(minLength: Tokens.Space.s2)
                    Text("Included").font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Compose.gutter)
                .padding(.vertical, Tokens.Space.s2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Included unchanged below your message, even when hidden.")
            .accessibilityLabel(showsQuote ? "Hide \(noun)" : "Show \(noun)")
            .accessibilityValue(showsQuote ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("compose-quote-toggle")
            if showsQuote {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Tokens.Space.s2) {
                        Button("Edit Quotation") {
                            model.isEditingSupplement = true
                            editsQuote = true
                        }
                        .accessibilityIdentifier("compose-edit-quote")
                        Spacer()
                    }
                    .controlSize(.small)
                    .disabled(!model.isEditable)
                    .padding(.horizontal, Tokens.Compose.gutter)
                    .padding(.bottom, Tokens.Space.s2)
                    ScrollView {
                        Text(quote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tokens.Compose.gutter)
                            .padding(.bottom, Tokens.Space.s2)
                    }
                    .frame(minHeight: Tokens.Space.s16, maxHeight: Tokens.Layout.quoteMaxHeight)
                }
                .ternTransition(.disclosure)
            }
        }
        .background(Tokens.Surface.muted)
        .overlay(alignment: .top) { Divider() }
        .ternAnimation(value: showsQuote, duration: Tokens.Motion.slow)
    }

    /// Stands where the quote goes until Gmail gives the original, or the
    /// message that a new message forwards as an attachment.
    private var originalStatus: some View {
        let kind = model.draft?.kind
        let isFile = kind == .new
        let failed = model.originalImportFailed
        let name = switch kind {
        case .forward?: "Forwarded Message"
        case .new?: SyncEngine.forwardedMessageFilename
        default: "Quoted Text"
        }
        let leaveOutHelp = switch kind {
        case .forward?: "Forward without the original message and its files."
        case .new?: "Send without the forwarded message."
        default: "Reply without quoting the original message."
        }
        return HStack(spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s2) {
                // Keeps the icon and name where the quote's toggle puts them.
                Color.clear.frame(width: Tokens.Space.s3, height: 0)
                Image(systemName: failed ? "exclamationmark.triangle" : isFile ? "paperclip" : "text.quote")
                    .frame(width: Tokens.Control.icon)
                Text(name)
                    .font(.caption.weight(.medium))
                Spacer(minLength: Tokens.Space.s2)
                if failed {
                    Text(isFile ? "Couldn't attach" : "Couldn't load").font(.caption)
                } else {
                    Text(isFile ? "Attaching…" : "Loading…").font(.caption).ternDelayedLoading()
                }
            }
            .foregroundStyle(.secondary)
            if failed {
                Button("Retry") { model.retryOriginal() }
                Button("Leave Out") { model.leaveOutOriginal() }
                    .help(leaveOutHelp)
            }
        }
        .controlSize(.small)
        .disabled(!model.isEditable)
        .padding(.horizontal, Tokens.Compose.gutter)
        .padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Surface.muted)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose-original-status")
    }
}
