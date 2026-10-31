import Foundation

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
