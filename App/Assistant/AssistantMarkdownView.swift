import AppKit
import SwiftUI

/// Model output is text. Only the separate, validated mail cards can navigate.
struct AssistantMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ForEach(AssistantMarkdown.parse(text)) { block in
                blockView(block)
            }
        }
        .font(.body)
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: AssistantMarkdown.Block) -> some View {
        if block.kind == .table {
            table(block)
        } else {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                if block.quoteDepth > 0 {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .fill(.secondary)
                        .frame(width: Tokens.Border.focus)
                        .accessibilityHidden(true)
                }
                if let marker = block.marker {
                    Text(marker).foregroundStyle(.secondary)
                        .frame(minWidth: Tokens.Space.s4, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                blockContent(block)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, CGFloat(min(max(block.listDepth - 1, 0), 4)) * Tokens.Space.s3)
        }
    }

    @ViewBuilder private func blockContent(_ block: AssistantMarkdown.Block) -> some View {
        switch block.kind {
        case .code:
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack {
                    Text(block.language ?? "Code").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy code", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(block.text.characters), forType: .string)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy code")
                }
                ScrollView(.horizontal) {
                    Text(String(block.text.characters))
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.bottom, Tokens.Space.s1)
                }
            }
            .padding(Tokens.Space.s3)
            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        case .heading:
            Text(block.text).font(headingFont(block.headingLevel))
                .accessibilityAddTraits(.isHeader)
        case .rule:
            Divider()
        case .paragraph, .table:
            Text(block.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func table(_ block: AssistantMarkdown.Block) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: Tokens.Space.s4, verticalSpacing: Tokens.Space.s2) {
                ForEach(block.rows) { row in
                    GridRow {
                        ForEach(row.cells.indices, id: \.self) { index in
                            Text(row.cells[index])
                                .font(row.isHeader ? .body.weight(.semibold) : .body)
                                .frame(maxWidth: Tokens.Layout.attachmentWidth, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if row.isHeader { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(Tokens.Space.s3)
        }
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        default: .headline
        }
    }
}

/// Foundation supplies CommonMark block identities. No HTML or URL is executed,
/// and input/block limits keep an unusually large reply from stalling the view.
enum AssistantMarkdown {
    enum Kind: Equatable { case paragraph, heading, code, rule, table }
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
        if input.count > bounded.count {
            blocks.append(Block(id: -2, text: AttributedString("Response shortened for display. Copy response to read the full text.")))
        }
        return blocks
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
