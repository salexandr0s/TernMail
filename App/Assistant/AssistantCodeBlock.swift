import AppKit
import SwiftUI

/// A compact preview keeps long snippets out of the reading flow. Copy always
/// uses the complete, unchanged source, including its indentation and newlines.
struct AssistantCodeBlock: View {
    let source: String
    var language: String? = nil
    @State private var showsAll = false
    @State private var copied = false

    private var lines: [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines).components(separatedBy: "\n")
    }

    private var hasMore: Bool { lines.count > Tokens.AssistantFormatting.codePreviewLines }

    private var displayedSource: String {
        (showsAll ? lines : Array(lines.prefix(Tokens.AssistantFormatting.codePreviewLines)))
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(spacing: Tokens.Space.s2) {
                Text(language == "mermaid" ? "Diagram source" : (language ?? "Code"))
                    .font(Tokens.AssistantFormatting.metadataFont.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(language ?? "Code")
                Spacer(minLength: Tokens.Space.s2)
                Button {
                    NSPasteboard.general.replaceContents(with: source)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                .buttonStyle(.borderless).controlSize(.small)
                .help(copied ? "Copied" : "Copy code")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, Tokens.AssistantFormatting.inset)
            .padding(.top, Tokens.Space.s1)
            ScrollView(.horizontal) {
                Text(displayedSource)
                    .font(Tokens.AssistantFormatting.codeFont)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, Tokens.AssistantFormatting.inset)
                    .padding(.bottom, Tokens.AssistantFormatting.inset)
            }
            if hasMore {
                Button {
                    showsAll.toggle()
                } label: {
                    Text(showsAll ? "Show fewer lines" : "Show all \(lines.count) lines")
                        .frame(minHeight: Tokens.Space.s6)
                        .contentShape(Rectangle())
                }
                .font(Tokens.AssistantFormatting.metadataFont)
                .buttonStyle(.borderless).controlSize(.small)
                .accessibilityValue(showsAll ? "Expanded" : "Collapsed")
                .padding(.horizontal, Tokens.AssistantFormatting.inset)
                .padding(.bottom, Tokens.AssistantFormatting.inset)
            }
        }
        .lineSpacing(0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
        .ternOutline(radius: Tokens.AssistantFormatting.cornerRadius, style: .contrastOnly)
        .contextMenu {
            Button("Copy code", systemImage: "doc.on.doc") { NSPasteboard.general.replaceContents(with: source) }
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }
}
