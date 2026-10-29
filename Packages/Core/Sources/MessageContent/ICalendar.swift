import Foundation

/// One component of an iCalendar object (RFC 5545), such as VCALENDAR,
/// VEVENT or VTIMEZONE.
public struct ICalendarComponent: Codable, Sendable, Equatable {
    /// Upper-cased, like every name the parser returns.
    public var name: String
    public var properties: [ICalendarProperty]
    public var components: [ICalendarComponent]

    public init(name: String, properties: [ICalendarProperty] = [], components: [ICalendarComponent] = []) {
        self.name = name.uppercased()
        self.properties = properties
        self.components = components
    }

    public func property(_ name: String) -> ICalendarProperty? {
        let name = name.uppercased()
        return properties.first { $0.name == name }
    }

    public func properties(named name: String) -> [ICalendarProperty] {
        let name = name.uppercased()
        return properties.filter { $0.name == name }
    }

    public func components(named name: String) -> [ICalendarComponent] {
        let name = name.uppercased()
        return components.filter { $0.name == name }
    }

    /// Content lines ending in CRLF, folded at 75 octets.
    public func serialized() -> String {
        var lines: [String] = []
        appendLines(to: &lines)
        return lines.map(ICalendar.fold).joined()
    }

    private func appendLines(to lines: inout [String]) {
        lines.append("BEGIN:" + name)
        lines += properties.map(\.contentLine)
        for component in components { component.appendLines(to: &lines) }
        lines.append("END:" + name)
    }
}

public struct ICalendarProperty: Codable, Sendable, Equatable {
    public struct Parameter: Codable, Sendable, Equatable {
        public var name: String
        public var values: [String]

        public init(_ name: String, values: [String]) {
            self.name = name.uppercased()
            self.values = values
        }

        public init(_ name: String, value: String) {
            self.init(name, values: [value])
        }
    }

    public var name: String
    public var parameters: [Parameter]
    /// The value as written, TEXT escapes included.
    public var value: String

    public init(_ name: String, parameters: [Parameter] = [], value: String) {
        self.name = name.uppercased()
        self.parameters = parameters
        self.value = value
    }

    /// The first value of a parameter.
    public func parameter(_ name: String) -> String? {
        let name = name.uppercased()
        return parameters.first { $0.name == name }?.values.first
    }

    /// The value read as TEXT, with escapes undone.
    public var text: String { ICalendar.unescape(value) }

    var contentLine: String {
        var line = name
        for parameter in parameters {
            line += ";" + parameter.name + "=" + parameter.values.map(ICalendar.parameterValue).joined(separator: ",")
        }
        // A line break here would start a new property.
        return line + ":" + String(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" })
    }
}

public enum ICalendarError: Error, Sendable, Equatable {
    /// Over `ICalendar.maxSize`.
    case tooLarge
    /// BEGIN and END don't pair up, or components nest too deeply.
    case malformed
    case noCalendar
    case noEvent
    case missingUID
}

public enum ICalendar {
    /// Larger calendar data isn't parsed.
    public static let maxSize = 1_048_576
    /// VCALENDAR, VEVENT, VALARM is three levels. The cap keeps crafted input
    /// from nesting deep enough to exhaust the stack.
    static let maxDepth = 8

    /// The first VCALENDAR in `data`. Lines that aren't content lines are
    /// skipped. Folds are undone on the bytes before decoding, since a fold
    /// may split a multi-byte character.
    public static func parse(_ data: Data, charset: String? = nil) throws -> ICalendarComponent {
        guard data.count <= maxSize else { throw ICalendarError.tooLarge }
        let text = MIMEParts.decode(unfold(data), charset: charset)
        var stack: [ICalendarComponent] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            guard let property = contentLine(line) else { continue }
            switch property.name {
            case "BEGIN":
                guard stack.count < maxDepth else { throw ICalendarError.malformed }
                stack.append(ICalendarComponent(name: property.value.trimmingCharacters(in: .whitespaces)))
            case "END":
                let name = property.value.trimmingCharacters(in: .whitespaces).uppercased()
                guard let component = stack.popLast(), component.name == name else { throw ICalendarError.malformed }
                if let parent = stack.indices.last {
                    stack[parent].components.append(component)
                } else if component.name == "VCALENDAR" {
                    return component
                }
            default:
                guard let current = stack.indices.last else { continue }
                stack[current].properties.append(property)
            }
        }
        throw stack.isEmpty ? ICalendarError.noCalendar : ICalendarError.malformed
    }

    /// Removes each line break followed by a space or tab, with or without CR.
    static func unfold(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var unfolded: [UInt8] = []
        unfolded.reserveCapacity(bytes.count)
        var index = 0
        func isFoldSpace(_ offset: Int) -> Bool {
            offset < bytes.count && (bytes[offset] == 0x20 || bytes[offset] == 0x09)
        }
        while index < bytes.count {
            if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A, isFoldSpace(index + 2) {
                index += 3
            } else if bytes[index] == 0x0A, isFoldSpace(index + 1) {
                index += 2
            } else {
                unfolded.append(bytes[index])
                index += 1
            }
        }
        return Data(unfolded)
    }

    /// `name *(";" param) ":" value`, or nil for anything else.
    static func contentLine(_ line: Substring) -> ICalendarProperty? {
        var index = line.startIndex
        func token() -> String {
            let start = index
            while index < line.endIndex, line[index].isASCII, line[index].isLetter || line[index].isNumber || line[index] == "-" {
                index = line.index(after: index)
            }
            return line[start..<index].uppercased()
        }

        let name = token()
        guard !name.isEmpty else { return nil }
        var parameters: [ICalendarProperty.Parameter] = []
        while index < line.endIndex, line[index] == ";" {
            index = line.index(after: index)
            let parameterName = token()
            guard !parameterName.isEmpty, index < line.endIndex, line[index] == "=" else { return nil }
            index = line.index(after: index)
            var values: [String] = []
            while true {
                if index < line.endIndex, line[index] == "\"" {
                    let start = line.index(after: index)
                    guard let close = line[start...].firstIndex(of: "\"") else { return nil }
                    values.append(decodeCarets(line[start..<close]))
                    index = line.index(after: close)
                } else {
                    let start = index
                    while index < line.endIndex, !";:,\"".contains(line[index]) { index = line.index(after: index) }
                    values.append(decodeCarets(line[start..<index]))
                }
                guard index < line.endIndex, line[index] == "," else { break }
                index = line.index(after: index)
            }
            parameters.append(.init(parameterName, values: values))
        }
        guard index < line.endIndex, line[index] == ":" else { return nil }
        return ICalendarProperty(name, parameters: parameters, value: String(line[line.index(after: index)...]))
    }

    /// RFC 6868: `^n` is a line break, `^'` a double quote and `^^` a caret.
    private static func decodeCarets(_ value: Substring) -> String {
        guard value.contains("^") else { return String(value) }
        var decoded = ""
        var pendingCaret = false
        for character in value {
            if pendingCaret {
                switch character {
                case "n": decoded.append("\n")
                case "'": decoded.append("\"")
                case "^": decoded.append("^")
                default: decoded += "^" + String(character)
                }
                pendingCaret = false
            } else if character == "^" {
                pendingCaret = true
            } else {
                decoded.append(character)
            }
        }
        if pendingCaret { decoded.append("^") }
        return decoded
    }

    static func parameterValue(_ value: String) -> String {
        var encoded = ""
        for character in value {
            switch character {
            case "^": encoded += "^^"
            case "\"": encoded += "^'"
            case "\n", "\r\n", "\r": encoded += "^n"
            default: encoded.append(character)
            }
        }
        return encoded.contains(where: { ":;,".contains($0) }) ? "\"" + encoded + "\"" : encoded
    }

    /// TEXT escapes undone: `\\`, `\;`, `\,`, and `\n` or `\N`.
    public static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var text = ""
        var escaping = false
        for character in value {
            if escaping {
                text.append(character == "n" || character == "N" ? "\n" : character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                text.append(character)
            }
        }
        if escaping { text.append("\\") }
        return text
    }

    public static func escape(_ text: String) -> String {
        var value = ""
        for character in text {
            switch character {
            case "\\": value += "\\\\"
            case ";": value += "\\;"
            case ",": value += "\\,"
            case "\n", "\r\n", "\r": value += "\\n"
            default: value.append(character)
            }
        }
        return value
    }

    /// Breaks before any scalar that would take the line past 75 octets, so
    /// no UTF-8 sequence is split. The continuation's space counts.
    static func fold(_ line: String) -> String {
        var folded = String.UnicodeScalarView()
        var octets = 0
        for scalar in line.unicodeScalars {
            let size = String(scalar).utf8.count
            if octets + size > 75 {
                folded.append(contentsOf: "\r\n ".unicodeScalars)
                octets = 1
            }
            folded.append(scalar)
            octets += size
        }
        return String(folded) + "\r\n"
    }
}
