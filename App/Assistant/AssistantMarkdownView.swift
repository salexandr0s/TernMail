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
        .font(Tokens.AssistantFormatting.bodyFont)
        .lineSpacing(Tokens.Space.s0_5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: AssistantMarkdown.Block) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s1_5) {
            if let completed = block.isTaskCompleted {
                Image(systemName: completed ? "checkmark.square.fill" : "square")
                    .foregroundStyle(.secondary)
                    .frame(width: Tokens.Space.s4)
                    .accessibilityLabel(completed ? "Completed" : "To do")
            } else if let marker = block.marker {
                Text(marker).font(Tokens.AssistantFormatting.bodyFont.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: Tokens.Space.s4, alignment: .trailing)
                    .accessibilityHidden(true)
            } else if block.isListContinuation {
                Color.clear.frame(width: Tokens.Space.s4, height: 0)
                    .accessibilityHidden(true)
            }
            blockContent(block)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, CGFloat(min(block.quoteDepth, 3)) * Tokens.AssistantFormatting.listIndent)
        .overlay(alignment: .leading) {
            if block.quoteDepth > 0 {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .fill(contrast == .increased ? Color.primary : Color.secondary.opacity(Tokens.Opacity.outline))
                    .frame(width: Tokens.Border.focus)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, CGFloat(min(max(block.listDepth - 1, 0), 4)) * Tokens.AssistantFormatting.listIndent)
    }

    @ViewBuilder private func blockContent(_ block: AssistantMarkdown.Block) -> some View {
        if let diagram = block.diagram {
            AssistantDiagramView(diagram: diagram, source: String(block.text.characters))
        } else {
            switch block.kind {
            case .code:
                AssistantCodeBlock(source: String(block.text.characters), language: block.language)
            case .heading:
                Text(block.text).font(headingFont(block.headingLevel))
                    .accessibilityAddTraits(.isHeader)
            case .rule:
                VStack(spacing: 0) { Divider() }
                    .frame(maxWidth: .infinity)
            case .table:
                AssistantTableBlock(block: block)
            case .paragraph, .diagram:
                Text(block.text).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(block.isTaskCompleted == true ? .secondary : .primary)
                    .strikethrough(block.isTaskCompleted == true)
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        case 3: Tokens.AssistantFormatting.bodyFont.weight(.semibold)
        default: Tokens.AssistantFormatting.bodyFont.weight(.medium)
        }
    }

    private func spacing(before index: Int, in blocks: [AssistantMarkdown.Block]) -> CGFloat {
        guard index > 0 else { return 0 }
        let block = blocks[index], previous = blocks[index - 1]
        if block.kind == .heading { return block.headingLevel <= 2 ? Tokens.AssistantFormatting.sectionGap : Tokens.AssistantFormatting.blockGap }
        if block.isListContinuation { return Tokens.Space.s1_5 }
        if block.listDepth > 0, previous.listDepth > 0 { return Tokens.AssistantFormatting.listGap }
        if previous.kind == .heading { return previous.headingLevel <= 2 ? Tokens.Space.s1_5 : Tokens.Space.s1 }
        if block.quoteDepth > 0, previous.quoteDepth > 0 { return Tokens.Space.s1_5 }
        return Tokens.AssistantFormatting.blockGap
    }
}
