import AppKit
import SwiftUI

/// Wide tables retain columns; narrow tables flow labels and values on the same
/// line. Expansion belongs to the block so resizing cannot discard that choice.
struct AssistantTableBlock: View {
    let block: AssistantMarkdown.Block
    @State private var showsAll = false

    private var header: AssistantMarkdown.Row? { block.rows.first(where: \.isHeader) }
    private var dataRows: [AssistantMarkdown.Row] { block.rows.filter { !$0.isHeader } }
    private var hasMore: Bool { dataRows.count > Tokens.AssistantFormatting.tablePreviewRows }
    private var visibleRows: [AssistantMarkdown.Row] {
        let rows = showsAll ? dataRows : Array(dataRows.prefix(Tokens.AssistantFormatting.tablePreviewRows))
        return block.rows.filter(\.isHeader) + rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            ViewThatFits(in: .horizontal) {
                grid.fixedSize(horizontal: true, vertical: true)
                compactRows
            }
            if hasMore {
                Divider()
                Button { showsAll.toggle() } label: {
                    Text(showsAll ? "Show fewer rows" : "Show all \(dataRows.count) rows")
                        .frame(minHeight: Tokens.Space.s6)
                        .contentShape(Rectangle())
                }
                .font(Tokens.AssistantFormatting.metadataFont)
                .buttonStyle(.borderless).controlSize(.small)
                .accessibilityValue(showsAll ? "Expanded" : "Collapsed")
            }
        }
        .lineSpacing(0)
        .padding(Tokens.AssistantFormatting.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
        .ternOutline(radius: Tokens.AssistantFormatting.cornerRadius, style: .contrastOnly)
        .contextMenu {
            Button("Copy table", systemImage: "doc.on.doc") {
                let text = block.rows.map { $0.cells.map { String($0.characters) }.joined(separator: "\t") }
                    .joined(separator: "\n")
                NSPasteboard.general.replaceContents(with: text)
            }
        }
    }

    /// Resolve widths before Grid measures row heights. A max-width-only cell
    /// can be measured on one line, then wrap beyond its allocated row later.
    private var columnWidths: [CGFloat] {
        var widths = Array(repeating: Tokens.Space.s4, count: block.rows.map { $0.cells.count }.max() ?? 0)
        for row in block.rows {
            let size = NSFont.preferredFont(forTextStyle: row.isHeader ? .caption1 : .callout).pointSize
            for (column, cell) in row.cells.enumerated() {
                let text = NSMutableAttributedString(string: "")
                for run in cell.runs {
                    let intent = run.inlinePresentationIntent ?? []
                    let weight: NSFont.Weight = intent.contains(.stronglyEmphasized) ? .bold : (row.isHeader ? .semibold : .regular)
                    var font = intent.contains(.code) ? NSFont.monospacedSystemFont(
                        ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
                    if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    text.append(NSAttributedString(string: String(cell[run.range].characters), attributes: [.font: font]))
                }
                widths[column] = min(Tokens.Layout.attachmentWidth, max(widths[column], ceil(text.size().width)))
            }
        }
        return widths
    }

    private var grid: some View {
        let widths = columnWidths
        return Grid(alignment: .topLeading, horizontalSpacing: Tokens.Space.s3, verticalSpacing: Tokens.Space.s1_5) {
            ForEach(visibleRows) { row in
                GridRow {
                    ForEach(row.cells.indices, id: \.self) { column in
                        Text(row.cells[column].characters.isEmpty ? AttributedString("—") : row.cells[column])
                            .font(row.isHeader ? Tokens.AssistantFormatting.metadataFont.weight(.semibold) : Tokens.AssistantFormatting.supportingFont)
                            .foregroundStyle(row.isHeader ? .secondary : .primary)
                            .frame(width: widths[column], alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if row.isHeader, visibleRows.count > 1 { Divider().gridCellUnsizedAxes(.horizontal) }
            }
        }
    }

    private var compactRows: some View {
        let rows = visibleRows.filter { !$0.isHeader }
        return VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            ForEach(rows.isEmpty ? visibleRows : rows) { row in
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    ForEach(row.cells.indices, id: \.self) { column in
                        Text(field(row, column: column))
                            .font(Tokens.AssistantFormatting.supportingFont)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if row.id != (rows.last ?? visibleRows.last)?.id { Divider() }
            }
        }
    }

    private func field(_ row: AssistantMarkdown.Row, column: Int) -> AttributedString {
        var text = AttributedString()
        if !row.isHeader, let header, header.cells.indices.contains(column), !header.cells[column].characters.isEmpty {
            var label = header.cells[column]
            label.font = Tokens.AssistantFormatting.metadataFont.weight(.medium)
            label.foregroundColor = .secondary
            text.append(label)
            var colon = AttributedString(": ")
            colon.foregroundColor = .secondary
            text.append(colon)
        }
        text.append(row.cells[column].characters.isEmpty ? AttributedString("—") : row.cells[column])
        return text
    }
}
