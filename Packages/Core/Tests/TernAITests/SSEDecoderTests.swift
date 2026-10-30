import Foundation
import Testing
@testable import TernAI

@Suite struct SSEDecoderTests {
    @Test func decodesSplitUTF8CRLFAndMultilineData() throws {
        let bytes = Data("\u{FEFF}: keepalive\r\nevent: example\r\ndata: café\r\ndata: second\r\n\r\n".utf8)
        var decoder = SSEDecoder()
        var events: [SSEEvent] = []
        for byte in bytes { events += try decoder.append(Data([byte])) }
        try decoder.finish()
        #expect(events == [SSEEvent(name: "example", data: "café\nsecond")])
    }

    @Test func rejectsMalformedUTF8AndUnterminatedFrame() throws {
        var decoder = SSEDecoder()
        #expect(throws: AIProviderError.invalidResponse) {
            try decoder.append(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0xFF, 0x0A]))
        }
        var unfinished = SSEDecoder()
        _ = try unfinished.append(Data("data: incomplete\n".utf8))
        #expect(throws: AIProviderError.streamInterrupted) { try unfinished.finish() }
    }

    @Test func boundsLinesFramesAndEventCount() throws {
        var line = SSEDecoder()
        line.maxFrameBytes = 8
        #expect(throws: AIProviderError.responseLimit) { try line.append(Data("data: abcdef".utf8)) }
        var frame = SSEDecoder()
        frame.maxFrameBytes = 10
        #expect(throws: AIProviderError.responseLimit) { try frame.append(Data("data: abc\ndata: def\ndata: ghi\n\n".utf8)) }
        var events = SSEDecoder()
        events.maxEvents = 1
        #expect(throws: AIProviderError.responseLimit) { try events.append(Data("data: 1\n\ndata: 2\n\n".utf8)) }
    }
}
