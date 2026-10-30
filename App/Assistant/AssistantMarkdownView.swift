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
                    Button("Copy code", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(block.text.characters), forType: .string)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy code")
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
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .strokeBorder(outlineColor, lineWidth: Tokens.Border.hairline).allowsHitTesting(false)
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
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .strokeBorder(outlineColor, lineWidth: Tokens.Border.hairline).allowsHitTesting(false)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .headline
        }
    }

    private var outlineColor: Color { contrast == .increased ? .primary : Tokens.Surface.border }

    private func spacing(before index: Int, in blocks: [AssistantMarkdown.Block]) -> CGFloat {
        guard index > 0 else { return 0 }
        let block = blocks[index], previous = blocks[index - 1]
        if block.kind == .heading { return Tokens.Space.s4 }
        if block.listDepth > 0, previous.listDepth > 0 { return Tokens.Space.s1_5 }
        if previous.kind == .heading { return Tokens.Space.s2 }
        return Tokens.Space.s3
    }
}

/// Foundation supplies CommonMark block identities. No HTML or URL is executed,
/// and input/block limits keep an unusually large reply from stalling the view.
enum AssistantMarkdown {
    enum Kind: Equatable { case paragraph, heading, code, rule, table, diagram }
    struct Row: Identifiable {
        let id: Int
        let isHeader: Bool
        var cells: [AttributedString]
    }
    struct Block: Identifiable {
        let id: Int
        var kind = Kind.paragraph
        var text = AttributedString()
        var headingLevel = 0
        var language: String?
        var marker: String?
        var listDepth = 0
        var quoteDepth = 0
        var rows: [Row] = []
        var diagram: AssistantDiagram?
    }

    static func parse(_ input: String) -> [Block] {
        let bounded = String(input.prefix(131_072))
        guard let document = try? AttributedString(markdown: bounded, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )) else { return [Block(id: 0, text: AttributedString(bounded))] }
        var blocks: [Block] = []
        var activeID: Int?
        var activeCellID: Int?
        for run in document.runs {
            let components = run.presentationIntent?.components ?? []
            let tableID = components.first { if case .table = $0.kind { true } else { false } }?.identity
            let identity = tableID ?? components.first?.identity ?? 0
            var piece = AttributedString(document[run.range])
            piece.link = nil
            piece.imageURL = nil
            piece.presentationIntent = nil
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece.font = .system(.body, design: .monospaced)
            }
            if activeID != identity {
                guard blocks.count < 512 else {
                    blocks.append(Block(id: -1, text: AttributedString("Response too long to format. Use Copy response to read the full text.")))
                    break
                }
                blocks.append(makeBlock(id: identity, components: components, isTable: tableID != nil))
                activeID = identity
                activeCellID = nil
            }
            guard let index = blocks.indices.last else { continue }
            if tableID != nil {
                let row = components.first {
                    switch $0.kind { case .tableHeaderRow, .tableRow: true; default: false }
                }
                let rowID = row?.identity ?? identity
                if blocks[index].rows.last?.id != rowID {
                    let isHeader: Bool
                    if case .tableHeaderRow = row?.kind { isHeader = true } else { isHeader = false }
                    blocks[index].rows.append(Row(id: rowID, isHeader: isHeader, cells: []))
                    activeCellID = nil
                }
                guard let rowIndex = blocks[index].rows.indices.last else { continue }
                let cellID = components.first?.identity ?? rowID
                if activeCellID != cellID {
                    blocks[index].rows[rowIndex].cells.append(piece)
                    activeCellID = cellID
                } else if let cellIndex = blocks[index].rows[rowIndex].cells.indices.last {
                    blocks[index].rows[rowIndex].cells[cellIndex].append(piece)
                }
            } else {
                blocks[index].text.append(piece)
            }
        }
        var completeSources = completedMermaidSources(in: bounded)
        for index in blocks.indices where blocks[index].kind == .code && blocks[index].language == "mermaid" {
            let source = String(blocks[index].text.characters).trimmingCharacters(in: .newlines)
            guard let match = completeSources.firstIndex(of: source) else { continue }
            completeSources.remove(at: match)
            if let diagram = AssistantDiagram.parse(source) {
                blocks[index].kind = .diagram
                blocks[index].diagram = diagram
            }
        }
        if input.count > bounded.count {
            blocks.append(Block(id: -2, text: AttributedString("Response shortened for display. Copy response to read the full text.")))
        }
        return blocks
    }

    /// Foundation accepts an unfinished fence as a code block. Wait for a real
    /// closing fence before replacing streamed Mermaid source with a diagram.
    private static func completedMermaidSources(in input: String) -> [String] {
        var fence: (character: Character, count: Int, isMermaid: Bool)?
        var lines: [String] = []
        var completed: [String] = []
        for line in input.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if trimmed.count >= active.count, trimmed.allSatisfy({ $0 == active.character }) {
                    if active.isMermaid { completed.append(lines.joined(separator: "\n").trimmingCharacters(in: .newlines)) }
                    fence = nil
                    lines = []
                } else if active.isMermaid { lines.append(line) }
            } else if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix(while: { $0 == character }).count
                guard count >= 3 else { continue }
                let language = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
                fence = (character, count, language == "mermaid")
            }
        }
        return completed
    }

    private static func makeBlock(id: Int, components: [PresentationIntent.IntentType], isTable: Bool) -> Block {
        var block = Block(id: id)
        if isTable { block.kind = .table; return block }
        var ordinal: Int?
        var ordered: Bool?
        for component in components {
            switch component.kind {
            case .header(let level): block.kind = .heading; block.headingLevel = level
            case .codeBlock(let language): block.kind = .code; block.language = language
            case .thematicBreak: block.kind = .rule
            case .blockQuote: block.quoteDepth += 1
            case .listItem(let value): if ordinal == nil { ordinal = value }
            case .orderedList: block.listDepth += 1; if ordered == nil { ordered = true }
            case .unorderedList: block.listDepth += 1; if ordered == nil { ordered = false }
            default: break
            }
        }
        if let ordinal { block.marker = ordered == true ? "\(ordinal)." : "•" }
        return block
    }
}
