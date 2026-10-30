import Foundation

struct SSEEvent: Equatable, Sendable {
    let name: String
    let data: String
}

/// Decodes bytes only after a complete line, preserving split UTF-8 characters.
struct SSEDecoder {
    private var line = Data()
    private var data: [String] = []
    private var eventName = "message"
    private var skipLF = false
    private var firstLine = true
    private var totalBytes = 0
    private var eventBytes = 0
    private var eventCount = 0
    var maxBytes = 2_097_152
    var maxFrameBytes = 262_144
    var maxEvents = 4096

    mutating func append(_ bytes: Data) throws -> [SSEEvent] {
        guard bytes.count <= maxBytes - totalBytes else { throw AIProviderError.responseLimit }
        totalBytes += bytes.count
        var events: [SSEEvent] = []
        for byte in bytes {
            if skipLF { skipLF = false; if byte == 10 { continue } }
            if byte == 13 || byte == 10 {
                if let event = try finishLine() { events.append(event) }
                skipLF = byte == 13
            } else {
                guard line.count < maxFrameBytes else { throw AIProviderError.responseLimit }
                line.append(byte)
            }
        }
        return events
    }

    func finish() throws {
        guard line.isEmpty, data.isEmpty, eventName == "message" else { throw AIProviderError.streamInterrupted }
    }

    private mutating func finishLine() throws -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        guard let text = String(data: line, encoding: .utf8) else { throw AIProviderError.invalidResponse }
        if text.isEmpty {
            defer { data.removeAll(keepingCapacity: true); eventName = "message"; eventBytes = 0 }
            guard !data.isEmpty else { return nil }
            eventCount += 1
            guard eventCount <= maxEvents else { throw AIProviderError.responseLimit }
            return SSEEvent(name: eventName, data: data.joined(separator: "\n"))
        }
        guard !text.hasPrefix(":") else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if parts[0] == "data" {
            eventBytes += value.utf8.count + 1
            guard eventBytes <= maxFrameBytes else { throw AIProviderError.responseLimit }
            data.append(value)
        } else if parts[0] == "event" { eventName = value }
        return nil
    }
}
