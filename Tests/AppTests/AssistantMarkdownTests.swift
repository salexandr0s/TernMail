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
}
