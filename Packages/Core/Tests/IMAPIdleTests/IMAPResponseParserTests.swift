import Foundation
import Testing
@testable import IMAPIdle

@Suite struct IMAPResponseParserTests {
    private let transcript = [
        "* OK Gimap ready for requests",
        "* CAPABILITY IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN AUTH=XOAUTH2 SASL-IR",
        "A1 OK Thats all she wrote!",
        "A2 OK [CAPABILITY IMAP4rev1 IDLE MOVE] user authenticated (Success)",
        "* FLAGS (\\Answered \\Flagged \\Draft \\Deleted \\Seen)",
        "* OK [PERMANENTFLAGS ()] Flags permitted.",
        "* 1234 EXISTS",
        "* 0 RECENT",
        "A3 OK [READ-ONLY] INBOX selected. (Success)",
        "+ idling",
        "* 1235 EXISTS",
        "* 17 EXPUNGE",
        "* 42 FETCH (FLAGS (\\Seen))",
        "* BYE System error",
    ].joined(separator: "\r\n") + "\r\n"

    private let expected: [IMAPResponse] = [
        .condition(.ok, code: nil),
        .capability(["IMAP4REV1", "UNSELECT", "IDLE", "NAMESPACE", "QUOTA", "ID", "XLIST", "CHILDREN", "AUTH=XOAUTH2", "SASL-IR"]),
        .tagged(tag: "A1", status: .ok, code: nil),
        .tagged(tag: "A2", status: .ok, code: .init(name: "CAPABILITY", arguments: ["IMAP4rev1", "IDLE", "MOVE"])),
        .other("FLAGS"),
        .condition(.ok, code: .init(name: "PERMANENTFLAGS", arguments: ["()"])),
        .exists(1234),
        .other("RECENT"),
        .tagged(tag: "A3", status: .ok, code: .init(name: "READ-ONLY")),
        .continuation,
        .exists(1235),
        .expunge(17),
        .fetch(42),
        .condition(.bye, code: nil),
    ]

    @Test func bytesOneAtATimeParseLikeOneChunk() throws {
        var whole = IMAPResponseParser()
        #expect(try whole.feed(Data(transcript.utf8)) == expected)

        var single = IMAPResponseParser()
        var responses: [IMAPResponse] = []
        for byte in Data(transcript.utf8) { responses += try single.feed([byte]) }
        #expect(responses == expected)
    }

    @Test func literalsAreSkippedByLengthIncludingTheirLineBreaks() throws {
        // The literal holds "A9 OK\r\n", which mustn't read as a response.
        let bytes = "* 12 FETCH (BODY[] {7}\r\nA9 OK\r\n)\r\n* 0 FETCH (X {0}\r\n)\r\nA1 OK done\r\n"
        var parser = IMAPResponseParser()
        #expect(try parser.feed(Data(bytes.utf8)) == [.fetch(12), .fetch(0), .tagged(tag: "A1", status: .ok, code: nil)])
    }

    @Test func taggedStatusesKeepTheirCodes() throws {
        var parser = IMAPResponseParser()
        let bytes = "A1 ok\r\nA2 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\nA3 BAD Unknown command\r\n+\r\n"
        #expect(try parser.feed(Data(bytes.utf8)) == [
            .tagged(tag: "A1", status: .ok, code: nil),
            .tagged(tag: "A2", status: .no, code: .init(name: "AUTHENTICATIONFAILED")),
            .tagged(tag: "A3", status: .bad, code: nil),
            .continuation,
        ])
    }

    @Test func oversizedLinesAndLiteralsAndGarbageAreProtocolErrors() {
        var long = IMAPResponseParser()
        #expect(throws: IMAPProtocolError.lineTooLong) {
            try long.feed(Data(("* OK " + String(repeating: "x", count: IMAPResponseParser.maxLineLength)).utf8))
        }
        var literal = IMAPResponseParser()
        #expect(throws: IMAPProtocolError.literalTooLong) {
            try literal.feed(Data("* 1 FETCH (BODY[] {\(IMAPResponseParser.maxLiteralLength + 1)}\r\n".utf8))
        }
        for garbage in ["garbage\r\n", "A1 MAYBE\r\n", "* \r\n", "* 5\r\n"] {
            var parser = IMAPResponseParser()
            #expect(throws: IMAPProtocolError.malformedResponse) { try parser.feed(Data(garbage.utf8)) }
        }
    }
}
