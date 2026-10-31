import Foundation
import Testing
@testable import MessageContent

@Suite struct ComposeDocumentTests {
    private typealias Run = ComposeDocument.Run
    private typealias Block = ComposeDocument.Block

    @Test func supportedFormattingSurvivesHTMLAndBack() throws {
        let link = try #require(URL(string: "https://example.com/a?b=1&c=2"))
        let document = ComposeDocument(blocks: [
            Block(runs: [Run("Hi "), Run("there", bold: true), Run(" & "), Run("you", italic: true, underline: true)]),
            Block(runs: []),
            Block(.bulleted(level: 0), runs: [Run("one")]),
            Block(.bulleted(level: 1), runs: [Run("nested "), Run("link", link: link)]),
            Block(.numbered(level: 0), runs: [Run("first")]),
            Block(.numbered(level: 0), runs: [Run("second")]),
            Block(runs: [Run("<script>not markup</script>")]),
            Block(runs: [Run("    four  two   three  "), Run(" three", bold: true)]),
        ])

        let html = document.html()
        let imported = HTMLImporter.importHTML(html)

        #expect(imported.document == document)
        #expect(!imported.droppedFormatting)
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("&nbsp;&nbsp;"))
        #expect(document.plainText() == """
            Hi there & you

            - one
                - nested link <https://example.com/a?b=1&c=2>
            1. first
            2. second
            <script>not markup</script>
                four  two   three   three
            """)
        let tabs = ComposeDocument(blocks: [Block(runs: [Run("\tone\t\ttwo")])])
        #expect(tabs.html() == "<div><span style=\"white-space:pre\">\t</span>one<span style=\"white-space:pre\">\t\t</span>two</div>")
    }

    @Test func importDropsActiveContentAndRemoteImagesAndKeepsTheQuote() {
        let html = """
            <html><head><style>p { color: red }</style><title>Ignored</title></head><body>
            <div dir="ltr">Hello <script>alert(1)</script><b>world</b>
            <img src="https://tracker.example.com/pixel.gif"><a href="javascript:alert(1)">click</a></div>
            <div class="gmail_quote"><div class="gmail_attr">On Monday, A wrote:</div>
            <blockquote class="gmail_quote"><p onclick="steal()">Earlier <img src="https://example.com/photo.jpg"></p><script>x()</script></blockquote></div>
            </body></html>
            """

        let result = HTMLImporter.importHTML(html)

        #expect(result.document.blocks.map(\.text) == ["Hello world click"])
        #expect(result.document.blocks.first?.runs.allSatisfy { $0.link == nil } == true)
        #expect(result.droppedFormatting)
        let tail = result.quotedTail ?? ""
        #expect(tail.contains("On Monday, A wrote:"))
        #expect(tail.contains("https://example.com/photo.jpg"))
        #expect(!tail.contains("script"))
        #expect(!tail.contains("onclick"))
    }
}

@Suite struct ReplyBuilderTests {
    private let me = EmailAddress(name: "Me", address: "me@example.com")
    private let jane = EmailAddress(name: "Jane", address: "jane@example.com")
    private let list = EmailAddress(address: "list@example.com")
    private let bob = EmailAddress(address: "bob@example.com")
    private let carol = EmailAddress(address: "carol@example.com")

    @Test func replyGoesToReplyToAndReplyAllDropsYouAndRepeats() {
        let original = OriginalMessage(
            threadID: "t1",
            from: [jane],
            replyTo: [list],
            to: [EmailAddress(name: "ME", address: "ME@example.com"), bob, list],
            cc: [carol, bob]
        )
        let own: Set<String> = ["me@example.com"]

        let reply = ReplyBuilder.draft(.reply, replyingTo: original, ownAddresses: own)
        let all = ReplyBuilder.draft(.replyAll, replyingTo: original, ownAddresses: own)
        let forward = ReplyBuilder.draft(.forward, replyingTo: original, ownAddresses: own)

        #expect(reply.to == [list])
        #expect(reply.cc.isEmpty)
        #expect(all.to == [list, bob])
        #expect(all.cc == [carol])
        #expect(forward.to.isEmpty && forward.cc.isEmpty)
    }

    @Test func replyingToYourOwnMessageGoesToItsRecipients() {
        let sent = OriginalMessage(threadID: "t1", from: [me], to: [jane], cc: [bob])
        let note = OriginalMessage(threadID: "t2", from: [me], to: [me])

        #expect(ReplyBuilder.draft(.reply, replyingTo: sent, ownAddresses: ["me@example.com"]).to == [jane])
        let all = ReplyBuilder.draft(.replyAll, replyingTo: sent, ownAddresses: ["me@example.com"])
        #expect(all.to == [jane])
        #expect(all.cc == [bob])
        #expect(ReplyBuilder.draft(.reply, replyingTo: note, ownAddresses: ["me@example.com"]).to == [me])
    }

    @Test func threadingHeadersGrowAndPrefixesAreNotDoubled() {
        let withReferences = OriginalMessage(
            threadID: "t1", from: [jane], subject: "RE: Plans",
            messageID: "<c@example.com>", inReplyTo: "<b@example.com>",
            references: ["<a@example.com>", "<b@example.com>"]
        )
        let withoutReferences = OriginalMessage(
            threadID: "t1", from: [jane], subject: "Fw: Plans",
            messageID: "<c@example.com>", inReplyTo: "<b@example.com>"
        )

        let reply = ReplyBuilder.draft(.reply, replyingTo: withReferences, ownAddresses: [])
        #expect(reply.subject == "RE: Plans")
        #expect(reply.inReplyTo == "<c@example.com>")
        #expect(reply.references == ["<a@example.com>", "<b@example.com>", "<c@example.com>"])
        #expect(reply.threadID == "t1")

        let forward = ReplyBuilder.draft(.forward, replyingTo: withoutReferences, ownAddresses: [])
        #expect(forward.subject == "Fw: Plans")
        #expect(forward.references == ["<b@example.com>", "<c@example.com>"])
        #expect(ReplyBuilder.draft(.reply, replyingTo: withoutReferences, ownAddresses: []).subject == "Re: Fw: Plans")
        #expect(OriginalMessage.messageIDs(in: "<a@x.com>,<b@x.com>\r\n <c@x.com>") == ["<a@x.com>", "<b@x.com>", "<c@x.com>"])
    }

    @Test func quotesKeepRemoteImagesAndDropActiveContent() throws {
        let original = OriginalMessage(
            threadID: "t1",
            from: [jane],
            date: Date(timeIntervalSince1970: 0),
            body: ExtractedBody(
                html: #"<p onclick="x()">Hi <img src="https://example.com/a.png"></p><script>bad()</script>"#,
                plainText: "Hi\n> earlier\n\nbye"
            )
        )
        let locale = Locale(identifier: "en_US_POSIX")
        let utc = try #require(TimeZone(identifier: "UTC"))

        let reply = ReplyBuilder.draft(.reply, replyingTo: original, ownAddresses: [], locale: locale, timeZone: utc)

        #expect(reply.quotedHTML.contains(#"<img src="https://example.com/a.png">"#))
        #expect(!reply.quotedHTML.contains("script"))
        #expect(!reply.quotedHTML.contains("onclick"))
        #expect(reply.quotedHTML.contains("Jane &lt;jane@example.com&gt; wrote:"))
        #expect(reply.quotedPlainText.hasSuffix("wrote:\n> Hi\n>> earlier\n>\n> bye"))

        let forward = ReplyBuilder.draft(.forward, replyingTo: original, ownAddresses: [], locale: locale, timeZone: utc)
        #expect(forward.quotedPlainText.hasPrefix("---------- Forwarded message ---------\nFrom: Jane <jane@example.com>\nDate: "))
        #expect(forward.quotedPlainText.hasSuffix("\n\nHi\n> earlier\n\nbye"))
    }
}
