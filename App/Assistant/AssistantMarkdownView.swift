import AppKit
import SwiftUI

/// Model output is text. Validated result cards provide navigation and actions.
struct AssistantMarkdownView: View {
    private let markdown: AssistantMessageMarkdown
    @Environment(\.colorSchemeContrast) private var contrast

    init(markdown: AssistantMessageMarkdown) { self.markdown = markdown }

    init(text: String) { markdown = AssistantMessageMarkdown(text: text) }

    var body: some View {
        let blocks = markdown.blocks
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
                if let completed = block.isTaskCompleted {
                    Image(systemName: completed ? "checkmark.square.fill" : "square")
                        .foregroundStyle(.secondary)
                        .frame(width: Tokens.Space.s4)
                        .accessibilityLabel(completed ? "Completed" : "To do")
                } else if let marker = block.marker {
                    Text(marker).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: Tokens.Space.s4, alignment: .trailing)
                        .accessibilityHidden(true)
                } else if block.isListContinuation {
                    Color.clear.frame(width: Tokens.Space.s4, height: 0)
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
                .foregroundStyle(block.quoteDepth > 0 || block.isTaskCompleted == true ? .secondary : .primary)
                .strikethrough(block.isTaskCompleted == true)
        }
    }

    private func table(_ block: AssistantMarkdown.Block) -> some View {
        ViewThatFits(in: .horizontal) {
            tableGrid(block).fixedSize(horizontal: true, vertical: false)
            tableRows(block)
        }
        .padding(Tokens.Space.s3)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md)
    }

    private func tableGrid(_ block: AssistantMarkdown.Block) -> some View {
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
    }

    private func tableRows(_ block: AssistantMarkdown.Block) -> some View {
        let header = block.rows.first(where: \.isHeader)
        let rows = block.rows.filter { !$0.isHeader }
        return VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ForEach(rows.isEmpty ? block.rows : rows) { row in
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    ForEach(row.cells.indices, id: \.self) { column in
                        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                            if !row.isHeader, let header, header.cells.indices.contains(column),
                               !header.cells[column].characters.isEmpty {
                                Text(header.cells[column]).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(row.cells[column].characters.isEmpty ? AttributedString("—") : row.cells[column])
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if row.id != (rows.last ?? block.rows.last)?.id { Divider() }
            }
        }
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
        if block.isListContinuation { return Tokens.Space.s2 }
        if block.listDepth > 0, previous.listDepth > 0 { return Tokens.Space.s1_5 }
        if previous.kind == .heading { return Tokens.Space.s2 }
        return Tokens.Space.s3
    }
}
