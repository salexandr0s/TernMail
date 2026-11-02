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
        var isListContinuation = false
        var isTaskCompleted: Bool?
        var quoteDepth = 0
        var tableColumnCount = 0
        var rows: [Row] = []
        var diagram: AssistantDiagram?
    }

    private static let maximumTableColumns = 32
    private static let maximumTableRows = 256
    private static let maximumTableCells = 4_096

    private struct SourceFence {
        let character: Character
        let count: Int
        let quoteDepth: Int
        let listIndent: Int
    }

    /// `isBounded: false` lifts the display limits, for copying a whole reply.
    static func parse(_ input: String, isBounded: Bool = true) -> [Block] {
        let bounded = isBounded ? String(input.prefix(131_072)) : input
        let wasShortened = input.count > bounded.count
        guard !tableNeedsRawFallback(in: bounded) else { return rawBlocks(bounded, wasShortened: wasShortened) }
        guard let document = try? AttributedString(markdown: bounded, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: true
        )) else { return rawBlocks(bounded, wasShortened: wasShortened) }
        var blocks: [Block] = []
        var activeID: Int?
        var seenListItems = Set<Int>()
        var allocatedTableCells = 0
        for run in document.runs {
            let components = run.presentationIntent?.components ?? []
            let tableID = components.first { if case .table = $0.kind { true } else { false } }?.identity
            let identity = tableID ?? components.first?.identity ?? 0
            var piece = AttributedString(document[run.range])
            piece.link = nil
            piece.imageURL = nil
            piece.presentationIntent = nil
            piece.markdownSourcePosition = nil
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece.font = .system(.body, design: .monospaced)
            }
            if activeID != identity {
                guard !isBounded || blocks.count < 512 else {
                    blocks.append(Block(id: -1, text: AttributedString("Response too long to format. Use Copy response to read the full text.")))
                    break
                }
                var block = makeBlock(id: identity, components: components, isTable: tableID != nil)
                if let listItem = components.first(where: { if case .listItem = $0.kind { true } else { false } }) {
                    block.isListContinuation = !seenListItems.insert(listItem.identity).inserted
                    if block.isListContinuation { block.marker = nil }
                }
                if block.kind == .paragraph, block.marker != nil,
                   run.inlinePresentationIntent?.contains(.code) != true,
                   piece.characters.count >= 4,
                   let position = run.markdownSourcePosition, let range = Range(position, in: bounded),
                   let completed = taskState(in: bounded[range]) {
                    block.isTaskCompleted = completed
                    let end = piece.characters.index(piece.startIndex, offsetBy: 4)
                    piece.removeSubrange(piece.startIndex..<end)
                }
                blocks.append(block)
                activeID = identity
            }
            guard let index = blocks.indices.last else { continue }
            if tableID != nil {
                let row = components.first {
                    switch $0.kind { case .tableHeaderRow, .tableRow: true; default: false }
                }
                let rowID = row?.identity ?? identity
                if blocks[index].rows.last?.id != rowID {
                    let columns = blocks[index].tableColumnCount
                    guard (1...maximumTableColumns).contains(columns), blocks[index].rows.count < maximumTableRows,
                          allocatedTableCells <= maximumTableCells - columns else {
                        return rawBlocks(bounded, wasShortened: wasShortened)
                    }
                    allocatedTableCells += columns
                    let isHeader: Bool
                    if case .tableHeaderRow = row?.kind { isHeader = true } else { isHeader = false }
                    blocks[index].rows.append(Row(id: rowID, isHeader: isHeader,
                        cells: Array(repeating: AttributedString(), count: blocks[index].tableColumnCount)))
                }
                guard let rowIndex = blocks[index].rows.indices.last else { continue }
                guard let cell = components.first(where: { if case .tableCell = $0.kind { true } else { false } }),
                      case .tableCell(let column) = cell.kind,
                      blocks[index].rows[rowIndex].cells.indices.contains(column) else {
                    return rawBlocks(bounded, wasShortened: wasShortened)
                }
                blocks[index].rows[rowIndex].cells[column].append(piece)
            } else {
                blocks[index].text.append(piece)
            }
        }
        var completeSources = completedMermaidSources(in: bounded)
        for index in blocks.indices where blocks[index].kind == .code && blocks[index].language == "mermaid" {
            let source = String(blocks[index].text.characters).trimmingCharacters(in: .newlines)
            let normalizedSource = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map(containerLine).joined(separator: "\n")
            guard let match = completeSources.firstIndex(of: normalizedSource) else { continue }
            completeSources.remove(at: match)
            if let diagram = AssistantDiagram.parse(source) {
                blocks[index].kind = .diagram
                blocks[index].diagram = diagram
            }
        }
        if wasShortened {
            blocks.append(Block(id: -2, text: AttributedString("Response shortened for display. Copy response to read the full text.")))
        }
        return blocks
    }

    private static func rawBlocks(_ input: String, wasShortened: Bool) -> [Block] {
        var blocks = [Block(id: 0, text: AttributedString(input))]
        if wasShortened {
            blocks.append(Block(id: -2, text: AttributedString("Response shortened for display. Copy response to read the full text.")))
        }
        return blocks
    }

    /// Check source dimensions before Foundation pads missing cells. Large or
    /// lossy tables stay as original text, including when copying a whole reply.
    static func tableNeedsRawFallback(in input: String) -> Bool {
        var previous: String?
        var table: (columns: Int, rows: Int)?
        var cells = 0
        var fence: SourceFence?
        for rawLine in input.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = containerLine(rawLine)
            if let active = fence {
                if rawLine.allSatisfy(\.isWhitespace) { continue }
                if let content = fenceContent(rawLine, quoteDepth: active.quoteDepth, listIndent: active.listIndent) {
                    let spaces = content.prefix(while: { $0 == " " }).count
                    let closing = content.dropFirst(spaces).trimmingCharacters(in: .whitespaces)
                    if spaces <= 3, closing.count >= active.count,
                       closing.allSatisfy({ $0 == active.character }) { fence = nil }
                    continue
                }
                // A fence inside a quote or list ends with that container. The
                // next source line can contain a real table and must be checked.
                fence = nil
            }
            if let opening = sourceFence(rawLine) {
                fence = opening
                table = nil; previous = nil
                continue
            }
            if line.isEmpty { table = nil; previous = nil; continue }
            if var active = table {
                active.rows += 1
                cells += active.columns
                if active.rows > maximumTableRows || cells > maximumTableCells
                    || tableColumns(line).count > active.columns || isEmptyTableLine(line) { return true }
                table = active
            } else if let previous, let columns = delimiterColumns(line),
                      tableColumns(previous).count == columns,
                      tableColumns(previous).hasPipe || line.contains("|") {
                cells += columns
                if columns > maximumTableColumns || cells > maximumTableCells || isEmptyTableLine(previous) { return true }
                table = (columns, 1)
            }
            previous = line
        }
        return false
    }

    private static func sourceFence(_ source: Substring) -> SourceFence? {
        var line = source
        var quoteDepth = 0
        var listIndent = 0
        while true {
            let spaces = line.prefix(while: { $0 == " " }).count
            guard spaces <= 3 else { return nil }
            let content = line.dropFirst(spaces)
            if content.first == ">", listIndent == 0 {
                quoteDepth += 1
                line = content.dropFirst()
                if line.first == " " { line = line.dropFirst() }
                continue
            }
            var rest = content
            let markerLength: Int
            if let first = rest.first, "-+*".contains(first) {
                rest = rest.dropFirst()
                markerLength = 1
            } else {
                let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
                rest = rest.dropFirst(digits.count)
                guard (1...9).contains(digits.count), rest.first == "." || rest.first == ")" else { line = content; break }
                rest = rest.dropFirst()
                markerLength = digits.count + 1
            }
            let gap = rest.prefix(while: { $0 == " " }).count
            guard gap <= 4 else { return nil }
            guard gap > 0 else { line = content; break }
            listIndent += spaces + markerLength + gap
            line = rest.dropFirst(gap)
        }
        guard let character = line.first, character == "`" || character == "~" else { return nil }
        let count = line.prefix(while: { $0 == character }).count
        guard count >= 3, character != "`" || !line.dropFirst(count).contains("`") else { return nil }
        return SourceFence(character: character, count: count, quoteDepth: quoteDepth, listIndent: listIndent)
    }

    private static func fenceContent(_ source: Substring, quoteDepth: Int, listIndent: Int) -> Substring? {
        var line = source
        for _ in 0..<quoteDepth {
            let spaces = line.prefix(while: { $0 == " " }).count
            guard spaces <= 3 else { return nil }
            line = line.dropFirst(spaces)
            guard line.first == ">" else { return nil }
            line = line.dropFirst()
            if line.first == " " { line = line.dropFirst() }
        }
        guard line.prefix(listIndent).allSatisfy({ $0 == " " }), line.count >= listIndent else { return nil }
        return line.dropFirst(listIndent)
    }

    private static func containerLine(_ source: Substring) -> String {
        var line = source.drop(while: \.isWhitespace)
        while line.first == ">" { line = line.dropFirst().drop(while: \.isWhitespace) }
        if let first = line.first, "-+*".contains(first), line.dropFirst().first?.isWhitespace == true {
            line = line.dropFirst().drop(while: \.isWhitespace)
        } else {
            let digits = line.prefix(while: \.isNumber)
            let rest = line.dropFirst(digits.count)
            if (1...9).contains(digits.count), rest.first == "." || rest.first == ")",
               rest.dropFirst().first?.isWhitespace == true {
                line = rest.dropFirst().drop(while: \.isWhitespace)
            }
        }
        return String(line).trimmingCharacters(in: .whitespaces)
    }

    private static func tableColumns(_ line: String) -> (count: Int, hasPipe: Bool) {
        var pipes = 0
        var escaped = false
        var endsWithPipe = false
        for character in line {
            endsWithPipe = character == "|" && !escaped
            if endsWithPipe { pipes += 1 }
            escaped = character == "\\" ? !escaped : false
        }
        return (pipes + 1 - (line.first == "|" ? 1 : 0) - (endsWithPipe ? 1 : 0), pipes > 0)
    }

    private static func delimiterColumns(_ line: String) -> Int? {
        var value = line[...]
        if value.first == "|" { value = value.dropFirst() }
        if value.last == "|" { value = value.dropLast() }
        var columns = 0
        for cell in value.split(separator: "|", omittingEmptySubsequences: false) {
            var content = cell.trimmingCharacters(in: .whitespaces)[...]
            if content.first == ":" { content = content.dropFirst() }
            if content.last == ":" { content = content.dropLast() }
            guard !content.isEmpty, content.allSatisfy({ $0 == "-" }) else { return nil }
            columns += 1
        }
        return columns > 0 ? columns : nil
    }

    private static func isEmptyTableLine(_ line: String) -> Bool {
        line.allSatisfy { $0 == "|" || $0.isWhitespace }
    }

    /// Check the source as well as the parsed text so escaped brackets and code
    /// stay literal. A checkbox is only recognized at the start of a list item.
    private static func taskState(in source: Substring) -> Bool? {
        let prefix = source.prefix(4)
        guard prefix.count == 4, prefix.last?.isWhitespace == true else { return nil }
        switch prefix.prefix(3) {
        case "[ ]": return false
        case "[x]", "[X]": return true
        default: return nil
        }
    }

    /// Foundation accepts an unfinished fence as a code block. Wait for a real
    /// closing fence before replacing streamed Mermaid source with a diagram.
    private static func completedMermaidSources(in input: String) -> [String] {
        var fence: (character: Character, count: Int, isMermaid: Bool)?
        var lines: [String] = []
        var completed: [String] = []
        for line in input.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = containerLine(line)
            if let active = fence {
                if trimmed.count >= active.count, trimmed.allSatisfy({ $0 == active.character }) {
                    if active.isMermaid { completed.append(lines.joined(separator: "\n").trimmingCharacters(in: .newlines)) }
                    fence = nil
                    lines = []
                } else if active.isMermaid { lines.append(trimmed) }
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
        if isTable { block.kind = .table }
        var ordinal: Int?
        var ordered: Bool?
        for component in components {
            switch component.kind {
            case .header(let level): block.kind = .heading; block.headingLevel = level
            case .codeBlock(let language): block.kind = .code; block.language = language
            case .thematicBreak: block.kind = .rule
            case .table(let columns): block.tableColumnCount = columns.count
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
