import Foundation
import Testing
@testable import Tern

struct AssistantMarkdownTests {
    @Test @MainActor func unchangedMessageTextReusesLazyPresentation() {
        var message = AssistantMessage(isUser: false, text: "**Read** the proposal.", state: .streaming)
        let presentation = message.markdown
        #expect(presentation.preparationCount == 0)

        _ = AssistantMarkdownView(markdown: message.markdown).body
        #expect(presentation.preparationCount == 1)
        let sameText = message.text
        message.text = sameText
        message.state = .completed
        message.draftIDs.append("draft")
        #expect(message.markdown === presentation)
        for _ in 0..<100 { _ = AssistantMarkdownView(markdown: message.markdown).body }
        #expect(presentation.preparationCount == 1)
        #expect(String(presentation.blocks[0].text.characters) == "Read the proposal.")
    }

    @Test @MainActor func copiedMessageEditsAndRetryResetReplaceOnlyTheirPresentation() {
        let original = AssistantMessage(isUser: false, text: "First paragraph.")
        let presentation = original.markdown
        _ = presentation.blocks
        var edited = original
        #expect(edited.markdown === presentation)

        edited.text += "\n\nSecond paragraph."
        #expect(edited.id == original.id)
        #expect(edited.markdown !== presentation)
        #expect(edited.markdown.preparationCount == 0)
        #expect(edited.markdown.blocks.map { String($0.text.characters) } == ["First paragraph.", "Second paragraph."])
        #expect(presentation.blocks.map { String($0.text.characters) } == ["First paragraph."])

        edited.text = ""
        #expect(edited.markdown.blocks.isEmpty)
        edited.text = "# Retried reply"
        #expect(edited.markdown.blocks.first?.kind == .heading)
        #expect(edited.markdown.blocks.first.map { String($0.text.characters) } == "Retried reply")
        #expect(presentation.preparationCount == 1)
    }

    @Test func preservesHeadingsListsQuotesAndCodeAsSeparateBlocks() {
        let blocks = AssistantMarkdown.parse("""
        # Priorities

        - Read the proposal
        - Reply tomorrow
          - Include the estimate

        > The deadline is Friday.

        ```swift
        let count = 2
        ```
        """)

        #expect(blocks.first?.kind == .heading)
        #expect(blocks.first?.headingLevel == 1)
        #expect(blocks.filter { $0.marker == "•" }.count == 3)
        #expect(blocks.contains { $0.listDepth == 2 })
        #expect(blocks.contains { $0.quoteDepth == 1 && String($0.text.characters) == "The deadline is Friday." })
        #expect(blocks.last?.kind == .code)
        #expect(blocks.last?.language == "swift")
        #expect(blocks.last.map { String($0.text.characters).contains("let count = 2") } == true)
    }

    @Test func generatedURLsImagesAndHTMLStayInertText() {
        let blocks = AssistantMarkdown.parse("""
        <script>window.location = 'https://example.invalid'</script>

        **Read** [this mail](https://example.invalid/mail) and ![remote image](https://example.invalid/image.png), *then* ~~remove~~ it.

        | Source | Detail |
        | --- | --- |
        | [Untrusted](tern://mail/unknown) | **Text** |
        """)
        let texts = blocks.flatMap { [$0.text] + $0.rows.flatMap(\.cells) }

        #expect(texts.contains { String($0.characters).contains("<script>") })
        #expect(texts.contains { String($0.characters).contains("this mail") })
        #expect(texts.contains { String($0.characters).contains("remote image") })
        for text in texts {
            for run in text.runs {
                #expect(run.link == nil)
                #expect(run.imageURL == nil)
                #expect(run.presentationIntent == nil)
            }
        }
        #expect(texts.contains { $0.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true } })
        #expect(texts.contains { $0.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true } })
        #expect(texts.contains { $0.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true } })
    }

    @Test func preservesTableCellBoundariesAcrossInlineFormatting() throws {
        let blocks = AssistantMarkdown.parse("""
        | Sender | Due | Status |
        | --- | --- | --- |
        | **Alex** Kim | | Waiting |
        | | Friday | |
        """)
        let table = try #require(blocks.first)

        #expect(table.kind == .table)
        #expect(table.rows.count == 3)
        #expect(table.rows.first?.isHeader == true)
        #expect(table.rows[1].cells.map { String($0.characters) } == ["Alex Kim", "", "Waiting"])
        #expect(table.rows.last?.cells.map { String($0.characters) } == ["", "Friday", ""])
    }

    @Test func nestedTablePreservesContainersEscapedPipesAndBackticks() throws {
        let markdown = """
        > 3. | Source | Detail |
        >    | --- | --- |
        >    | `a\\|b` | `` `quoted` `` |
        """
        let table = try #require(AssistantMarkdown.parse(markdown).first)
        #expect(table.kind == .table)
        #expect(table.quoteDepth == 1)
        #expect(table.listDepth == 1)
        #expect(table.marker == "3.")
        #expect(table.rows[1].cells.map { String($0.characters) } == ["a|b", "`quoted`"])
        #expect(AssistantMarkdown.plainText(markdown) == "3. Source\tDetail\n\ta|b\t`quoted`")
    }

    @Test func oversizedTablesFallBackBeforePaddingAndCopyAllSourceText() {
        for (columns, rows) in [(40, 2), (2, 300), (32, 140)] {
            let header = "| " + (1...columns).map { "Header \($0)" }.joined(separator: " | ") + " |"
            let delimiter = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
            let markdown = ([header, delimiter] + Array(repeating: "| x |", count: rows)).joined(separator: "\r\n")
            let blocks = AssistantMarkdown.parse(markdown)
            #expect(blocks.count == 1)
            #expect(blocks[0].kind == .paragraph)
            #expect(String(blocks[0].text.characters) == markdown)
            #expect(AssistantMarkdown.plainText(markdown) == markdown)
        }
        let wide = "| " + Array(repeating: "Header", count: 40).joined(separator: " | ") + " |\n| "
            + Array(repeating: "---", count: 40).joined(separator: " | ") + " |\n"
        let reply = wide + String(repeating: "tail", count: 40_000)
        let display = AssistantMarkdown.parse(reply)
        #expect(String(display[0].text.characters) == String(reply.prefix(131_072)))
        #expect(display.last?.id == -2)
        #expect(AssistantMarkdown.plainText(reply) == reply)
    }

    @Test func indentedCodeCannotHideOversizedTablesFromPreflight() {
        let header = "| " + Array(repeating: "Header", count: 33).joined(separator: " | ") + " |"
        let delimiter = "| " + Array(repeating: "---", count: 33).joined(separator: " | ") + " |"
        let table = header + "\n" + delimiter + "\n| x |"
        let quotedTable = table.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        for markdown in [
            "    ```text\n\n" + table,
            ">     ```text\n>\n" + quotedTable,
            "- ```text\n  literal code\n  ```\n\n" + table,
            "> ```text\n> literal code\n\n" + table,
        ] {
            // This guard runs before Foundation parses or pads any table cells.
            #expect(AssistantMarkdown.tableNeedsRawFallback(in: markdown))
            #expect(AssistantMarkdown.plainText(markdown) == markdown)
        }
        let fenced = "```text\n" + table + "\n```"
        #expect(!AssistantMarkdown.tableNeedsRawFallback(in: fenced))
        #expect(AssistantMarkdown.parse(fenced).first?.kind == .code)
    }

    @Test func tableFallbackPreservesExtraCellsAndEmptyRows() {
        for markdown in [
            "| A | B |\n| --- | --- |\n| x | y | extra |",
            "| A | B |\n| --- | --- |\n| | |\n| x | y |",
        ] {
            #expect(AssistantMarkdown.parse(markdown).allSatisfy { $0.kind == .paragraph })
            #expect(AssistantMarkdown.plainText(markdown) == markdown)
        }
    }

    @Test func copyKeepsNumberedHeadingsCodeAndNestedDiagrams() {
        let markdown = """
        7. # First
        8. ```swift
           let count = 2
           print(count)
           ```
        9. ```mermaid
           flowchart TD
           A --> B
           ```
        """
        let blocks = AssistantMarkdown.parse(markdown)
        #expect(blocks.map(\.marker) == ["7.", "8.", "9."])
        #expect(blocks.map(\.kind) == [.heading, .code, .diagram])
        #expect(AssistantMarkdown.plainText(markdown)
            == "7. First\n8. let count = 2\n\tprint(count)\n9. flowchart TD\n\tA --> B")
    }

    @Test func codeCopyPreservesIntentionalBlankLinesAndUnfinishedFences() throws {
        let closed = "```text\n\n  keep indent\n\n```"
        let block = try #require(AssistantMarkdown.parse(closed).first)
        #expect(block.kind == .code)
        #expect(String(block.text.characters) == "\n  keep indent\n\n")
        #expect(AssistantMarkdown.plainText(closed) == "\n  keep indent\n")
        let unfinished = "```swift\nlet count = 2"
        #expect(AssistantMarkdown.parse(unfinished).first?.kind == .code)
        #expect(AssistantMarkdown.plainText(unfinished) == "let count = 2")
        #expect(AssistantMarkdown.plainText(unfinished + "\n``` ") == "let count = 2")
    }

    @Test func checklistsPreserveCompletionFormattingAndLiteralBrackets() throws {
        let markdown = """
        - [ ] Read **the proposal**
          - [x] Request the estimate
        - [X] Reply to Alex
        - \\[x] Literal brackets
        - `[ ]` Code sample

        [ ] A paragraph, not a task
        """
        let blocks = AssistantMarkdown.parse(markdown)
        let tasks = blocks.filter { $0.isTaskCompleted != nil }
        #expect(tasks.map(\.isTaskCompleted) == [false, true, true])
        #expect(tasks.map { String($0.text.characters) } == ["Read the proposal", "Request the estimate", "Reply to Alex"])
        #expect(tasks[1].listDepth == 2)
        #expect(tasks[0].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(blocks.filter { $0.isTaskCompleted == nil }.map { String($0.text.characters) } == [
            "[x] Literal brackets", "[ ] Code sample", "[ ] A paragraph, not a task"
        ])
        #expect(AssistantMarkdown.plainText(markdown) == "☐ Read the proposal\n\t☑ Request the estimate\n☑ Reply to Alex\n• [x] Literal brackets\n• [ ] Code sample\n\n[ ] A paragraph, not a task")
    }

    @Test func continuedListParagraphsDoNotBecomeAdditionalTasks() {
        let markdown = """
        - [ ] Send the proposal

          Include the estimate.

          - Check the dates

          [x] This is a continuation, not a second task.
        """
        let blocks = AssistantMarkdown.parse(markdown)
        #expect(blocks.filter { $0.marker != nil }.count == 2)
        #expect(blocks.filter(\.isListContinuation).count == 2)
        #expect(blocks.filter { $0.isTaskCompleted != nil }.count == 1)
        #expect(AssistantMarkdown.plainText(markdown) == "☐ Send the proposal\n\n\tInclude the estimate.\n\t• Check the dates\n\n\t[x] This is a continuation, not a second task.")
    }

    @Test func onlyClosedSupportedMermaidFencesBecomeDiagrams() throws {
        let source = "flowchart TD\nA[Read proposal] --> B{Approved?}\nB -->|Yes| C(Send reply)"
        let open = "```mermaid\n" + source
        #expect(AssistantMarkdown.parse(open).first?.kind == .code)
        #expect(AssistantMarkdown.parse(open + "\n``").first?.kind == .code)
        let closed = try #require(AssistantMarkdown.parse(open + "\n```").first)
        #expect(closed.kind == .diagram)
        #expect(closed.diagram?.nodes.map(\.label) == ["Read proposal", "Approved?", "Send reply"])
        #expect(closed.diagram?.edges.last?.label == "Yes")
        #expect(String(closed.text.characters).trimmingCharacters(in: .newlines) == source)
        let mixed = AssistantMarkdown.parse(open + "\n```\n\n" + open)
        #expect(mixed.map(\.kind) == [.diagram, .code])
        #expect(AssistantMarkdown.parse("~~~mermaid\n" + source + "\n~~~").first?.kind == .diagram)
    }

    @Test func unsupportedDiagramsRemainCompleteInertCode() {
        let rejected = [
            "flowchart TD\nA --> B\nclick A \"https://example.invalid\"",
            "flowchart TD\nA --> B\nstyle A fill:red",
            "flowchart TD\nA[<img src=x>] --> B",
            "flowchart TD\nA --> B\nB --> A",
            "flowchart TD\nA --> B\nB -->",
            "flowchart TD\nA[First] --> B\nA[Different] --> C",
            "flowchart TD\nA -->|Yes| B\nA -->|No| B",
            "%%{init: {}}%%\nflowchart TD\nA --> B",
            "flowchart TD\nA --> B --> C --> D --> E --> F --> G --> H --> I"
        ]
        for source in rejected {
            #expect(AssistantDiagram.parse(source) == nil)
            let block = AssistantMarkdown.parse("```mermaid\n" + source + "\n```").first
            #expect(block?.kind == .code)
            #expect(block.map { String($0.text.characters).trimmingCharacters(in: .newlines) } == source)
        }
        #expect(AssistantDiagram.parse("flowchart TD\nA[" + String(repeating: "a", count: 81) + "] --> B") == nil)
        #expect(AssistantDiagram.parse(String(repeating: "x", count: 8_193)) == nil)
    }

    @Test func branchingDiagramFitsNarrowCardAndPreservesMerge() throws {
        let diagram = try #require(AssistantDiagram.parse("""
        graph TD
        A{Approved?} -->|Yes| B[Prepare reply]
        A -->|No| C[Ask for changes]
        B --> D[Review draft]
        C --> D
        """))
        let layout = AssistantDiagramLayout(diagram: diagram)
        #expect(diagram.ranks["D"] == 2)
        #expect(layout.size.width <= 264)
        #expect(layout.connections.count == 4)
        #expect(diagram.accessibleDescription.contains("Approved?, Yes, leads to Prepare reply."))
        #expect(diagram.accessibleDescription.contains("Ask for changes leads to Review draft."))
    }

    @Test func plainTextDropsSyntaxButKeepsListsTablesAndCode() {
        let text = AssistantMarkdown.plainText("""
        # Plan

        Read **the proposal** and *reply*.

        - First
          - Nested
        1. One

        ---

        | Name | Status |
        | --- | --- |
        | Alex | `Waiting` |

        ```swift
        let count = 2
        ```
        """)

        #expect(text == "Plan\n\nRead the proposal and reply.\n\n• First\n\t• Nested\n1. One\n\nName\tStatus\nAlex\tWaiting\n\nlet count = 2")
    }

    @Test @MainActor func copyingIgnoresTheDisplayLimits() {
        let reply = (1...600).map { "- Item \($0)" }.joined(separator: "\n")

        let message = AssistantMessage(isUser: false, text: reply)
        #expect(message.markdown.blocks.contains { $0.id < 0 })
        let text = AssistantMarkdown.plainText(reply)
        #expect(text.hasSuffix("• Item 600"))
        #expect(!text.contains("Response too long"))
    }

    @Test(arguments: ["TD", "BT", "LR", "RL"])
    func arrowsSkippingRanksAvoidOtherNodes(direction: String) throws {
        let diagram = try #require(AssistantDiagram.parse("""
        flowchart \(direction)
        A --> B[Review the proposal and confirm the final delivery date with the project team]
        A --> C
        B --> E
        C --> D
        D --> E
        """))
        let layout = AssistantDiagramLayout(diagram: diagram)
        for edge in diagram.edges {
            let connection = try #require(layout.connections.first { $0.id == edge.id })
            for node in diagram.nodes where node.id != edge.source && node.id != edge.target {
                let bounds = try #require(layout.nodeBounds[node.id])
                for (start, end) in zip(connection.route, connection.route.dropFirst()) {
                    for step in 1..<10 {
                        let fraction = CGFloat(step) / 10
                        let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                            y: start.y + (end.y - start.y) * fraction)
                        #expect(!bounds.contains(point))
                    }
                }
            }
        }
    }
}
