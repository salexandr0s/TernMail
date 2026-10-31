import AppKit
import SwiftUI

/// Model output is text. Only the separate, validated mail cards can navigate.
struct AssistantMarkdownView: View {
    let text: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let blocks = AssistantMarkdown.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                blockView(block).padding(.top, spacing(before: index, in: blocks))
            }
        }
        .font(.body)
        .lineSpacing(Tokens.Space.s0_5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: AssistantMarkdown.Block) -> some View {
        if let diagram = block.diagram {
            AssistantDiagramView(diagram: diagram, source: String(block.text.characters))
        } else if block.kind == .table {
            table(block)
        } else {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                if let marker = block.marker {
                    Text(marker).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: Tokens.Space.s4, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                blockContent(block)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, block.quoteDepth > 0 ? Tokens.Space.s3 : 0)
            .overlay(alignment: .leading) {
                if block.quoteDepth > 0 {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .fill(contrast == .increased ? Color.primary : Color.secondary)
                        .frame(width: Tokens.Border.focus)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(min(max(block.listDepth - 1, 0), 4)) * Tokens.Space.s3)
        }
    }

    @ViewBuilder private func blockContent(_ block: AssistantMarkdown.Block) -> some View {
        switch block.kind {
        case .code:
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(block.language == "mermaid" ? "Diagram source" : (block.language ?? "Code"))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Code", systemImage: "doc.on.doc") { copyCode(block) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy Code")
                }
                .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
                Divider()
                ScrollView(.horizontal) {
                    Text(String(block.text.characters))
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(Tokens.Space.s3)
                }
            }
            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .ternOutline(radius: Tokens.Radius.md)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { copyCode(block) }
            }
        case .heading:
            Text(block.text).font(headingFont(block.headingLevel))
                .accessibilityAddTraits(.isHeader)
        case .rule:
            Divider()
        case .paragraph, .table, .diagram:
            Text(block.text).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(block.quoteDepth > 0 ? .secondary : .primary)
        }
    }

    private func table(_ block: AssistantMarkdown.Block) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: Tokens.Space.s4, verticalSpacing: Tokens.Space.s2) {
                ForEach(block.rows) { row in
                    GridRow {
                        ForEach(row.cells.indices, id: \.self) { index in
                            Text(row.cells[index])
                                .font(row.isHeader ? .callout.weight(.semibold) : .callout)
                                .frame(maxWidth: Tokens.Layout.attachmentWidth, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if row.id != block.rows.last?.id { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(Tokens.Space.s3)
        }
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .headline
        }
    }

    private func copyCode(_ block: AssistantMarkdown.Block) {
        NSPasteboard.general.replaceContents(with: String(block.text.characters))
    }

    private func spacing(before index: Int, in blocks: [AssistantMarkdown.Block]) -> CGFloat {
        guard index > 0 else { return 0 }
        let block = blocks[index], previous = blocks[index - 1]
        if block.kind == .heading { return Tokens.Space.s4 }
        if block.listDepth > 0, previous.listDepth > 0 { return Tokens.Space.s1_5 }
        if previous.kind == .heading { return Tokens.Space.s2 }
        return Tokens.Space.s3
    }
}
