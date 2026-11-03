import Foundation
import Testing
@testable import TernAI

@Suite struct AIJSONTests {
    @Test func reconstructedObjectsKeepTheSameEncodedContentAndArrayOrder() throws {
        let first: AIJSON = .object([
            "z": .array([.object(["second": .number(2), "first": .number(1)]), .string("last")]),
            "a": .string("first")
        ])
        let second: AIJSON = .object([
            "a": .string("first"),
            "z": .array([.object(["first": .number(1), "second": .number(2)]), .string("last")])
        ])
        #expect(try first.jsonString() == #"{"a":"first","z":[{"first":1,"second":2},"last"]}"#)
        #expect(try first.encoded() == second.encoded())
    }

    @Test func slashHeavyUnicodeContentRoundTripsWithoutRedundantEscapes() throws {
        let text = "https://example.invalid/mail/Überblick/🕊️\n\"quoted\"\\path"
        let value: AIJSON = .object(["text": .string(text)])
        let encoded = try value.encoded()
        #expect(try AIJSON.decode(encoded) == value)
        #expect(try value.jsonString().contains("https://example.invalid/mail/"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("\\/"))
        #expect(encoded.count < (try JSONEncoder().encode(value)).count)
    }
}
