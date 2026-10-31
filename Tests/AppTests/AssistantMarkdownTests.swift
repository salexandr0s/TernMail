import Foundation
import Testing
@testable import Tern

struct AssistantMarkdownTests {
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

        **Read** [this mail](https://example.invalid/mail) and ![remote image](https://example.invalid/image.png).

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
    }

    @Test func preservesTableCellBoundariesAcrossInlineFormatting() throws {
        let blocks = AssistantMarkdown.parse("""
        | Sender | Status |
        | --- | --- |
        | **Alex** Kim | Waiting |
        """)
        let table = try #require(blocks.first)

        #expect(table.kind == .table)
        #expect(table.rows.count == 2)
        #expect(table.rows.first?.isHeader == true)
        #expect(table.rows.last?.cells.map { String($0.characters) } == ["Alex Kim", "Waiting"])
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

    @Test func copyingIgnoresTheDisplayLimits() {
        let reply = (1...600).map { "- Item \($0)" }.joined(separator: "\n")

        #expect(AssistantMarkdown.parse(reply).contains { $0.id < 0 })
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
                let center = try #require(layout.centers[node.id])
                let bounds = CGRect(x: center.x - layout.nodeSize.width / 2,
                                    y: center.y - layout.nodeSize.height / 2,
                                    width: layout.nodeSize.width, height: layout.nodeSize.height)
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
