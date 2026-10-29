import Testing
@testable import MessageContent

@Suite struct SearchTextTests {
    @Test func dropsHiddenContentAndKeepsWordsApart() {
        let html = """
            <html><head><title>Hidden title</title><style>.a{color:red}</style></head>
            <body><script>var hidden = 1;</script><!-- a hidden comment -->
            <p>Trail</p><p>map</p><div>caf&eacute; &amp; more&nbsp;text</div></body></html>
            """
        #expect(SearchText.body(html: html, plainText: nil) == "Trail map café & more text")
    }

    @Test func keepsTextThatOnlyLooksLikeMarkup() {
        #expect(SearchText.body(html: "<p>if a < b and c > d</p>", plainText: nil) == "if a < b and c > d")
        #expect(SearchText.body(html: "<header>Top</header><p>Body</p>", plainText: nil) == "Top Body")
        #expect(SearchText.body(html: "<a title=\"x > y\" href=it's>Link</a> after", plainText: nil) == "Link after")
    }

    @Test func headWithoutClosingTagEndsAtBody() {
        #expect(SearchText.body(html: "<head><meta charset=utf-8><body>Visible", plainText: nil) == "Visible")
    }

    @Test func prefersPlainText() {
        #expect(SearchText.body(html: "<p>html</p>", plainText: "plain\n\n  text") == "plain text")
        #expect(SearchText.body(html: "<p>html</p>", plainText: " \n ") == "html")
        #expect(SearchText.body(html: nil, plainText: nil).isEmpty)
    }

    @Test func capsTheLength() {
        let long = String(repeating: "word ", count: SearchText.limit)
        let text = SearchText.body(html: "<p>\(long)</p>", plainText: nil)
        #expect(text.count <= SearchText.limit)
        #expect(text.count > SearchText.limit - 10)
        #expect(SearchText.body(html: nil, plainText: long).count <= SearchText.limit)
    }
}
