import SwiftUI

/// Reference files are supplied to the assistant without becoming email attachments.
struct ComposeAssistantContextFilesView: View {
    enum Presentation { case attachments, errors }

    let model: ComposeAssistantModel
    var presentation: Presentation = .attachments

    var body: some View {
        switch presentation {
        case .attachments: attachments
        case .errors: errors
        }
    }

    @ViewBuilder private var attachments: some View {
        if !model.contextAttachments.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Label("Assistant reference files · Not sent with email", systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: Tokens.Space.s2) {
                        ForEach(model.contextAttachments) { file in
                            HStack(spacing: Tokens.Space.s2) {
                                if file.isLoading { ProgressView().controlSize(.mini) }
                                else {
                                    Image(systemName: file.errorMessage == nil ? "doc.text" : "exclamationmark.circle")
                                        .foregroundStyle(file.errorMessage == nil ? Color.secondary : Tokens.Status.error)
                                        .accessibilityHidden(true)
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
                            .background(Tokens.Surface.primary, in: .rect(cornerRadius: Tokens.Radius.md))
                            .ternOutline(radius: Tokens.Radius.md)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var errors: some View {
        if model.hasContextFileErrors {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                ForEach(model.contextAttachments) { file in
                    if let error = file.errorMessage {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Label(file.filename, systemImage: "exclamationmark.circle")
                                .font(.callout.weight(.semibold))
                            Text(error).font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: Tokens.Space.s2) {
                                Button("Retry") { model.retryContextFile(file.id) }.disabled(!model.canAddContextFiles)
                                Button("Remove") { model.removeContextFile(file.id) }
                            }
                            .controlSize(.small)
                        }
                        .padding(Tokens.Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Status.error.opacity(Tokens.Opacity.wash), in: .rect(cornerRadius: Tokens.Radius.md))
                    }
                }
            }
            .id("compose-context-errors")
        }
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}
