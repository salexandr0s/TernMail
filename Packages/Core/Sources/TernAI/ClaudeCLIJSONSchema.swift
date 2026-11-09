import Foundation

/// Validates the schema vocabulary used by Tern before accepting CLI-produced actions.
enum ClaudeCLIJSONSchema {
    private static let keywords: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items", "enum", "const",
        "anyOf", "oneOf", "allOf", "not", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        "multipleOf", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "pattern",
        "description", "title", "default", "examples", "format", "$schema", "$id",
    ]

    static func supports(_ schema: AIJSON, depth: Int = 0) -> Bool {
        guard depth <= 32 else { return false }
        if schema.boolValue != nil { return true }
        guard let object = schema.objectValue, Set(object.keys).isSubset(of: keywords) else { return false }
        if let properties = schema["properties"] {
            guard let fields = properties.objectValue,
                  fields.values.allSatisfy({ supports($0, depth: depth + 1) }) else { return false }
        }
        for key in ["items", "not", "additionalProperties"] {
            if let value = schema[key], !supports(value, depth: depth + 1) { return false }
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let value = schema[key] {
                guard let alternatives = value.arrayValue, !alternatives.isEmpty,
                      alternatives.allSatisfy({ supports($0, depth: depth + 1) }) else { return false }
            }
        }
        return true
    }

    static func matches(_ value: AIJSON, schema: AIJSON, depth: Int = 0) -> Bool {
        guard depth <= 32 else { return false }
        if let allowed = schema.boolValue { return allowed }
        guard let shape = schema.objectValue, Set(shape.keys).isSubset(of: keywords) else { return false }
        if let type = shape["type"] {
            let types = type.stringValue.map { [$0] } ?? type.arrayValue?.compactMap(\.stringValue) ?? []
            guard !types.isEmpty, types.contains(where: { hasType(value, $0) }) else { return false }
        }
        if let options = shape["enum"]?.arrayValue, !options.contains(value) { return false }
        if let constant = shape["const"], constant != value { return false }
        if let alternatives = shape["anyOf"]?.arrayValue,
           !alternatives.contains(where: { matches(value, schema: $0, depth: depth + 1) }) { return false }
        if let alternatives = shape["oneOf"]?.arrayValue,
           alternatives.filter({ matches(value, schema: $0, depth: depth + 1) }).count != 1 { return false }
        if let alternatives = shape["allOf"]?.arrayValue,
           !alternatives.allSatisfy({ matches(value, schema: $0, depth: depth + 1) }) { return false }
        if let negative = shape["not"], matches(value, schema: negative, depth: depth + 1) { return false }
        if let fields = value.objectValue {
            let properties = shape["properties"]?.objectValue ?? [:]
            if let required = shape["required"]?.arrayValue,
               !required.allSatisfy({ $0.stringValue.map { fields[$0] != nil } ?? false }) { return false }
            for (key, entry) in fields {
                if let field = properties[key] {
                    guard matches(entry, schema: field, depth: depth + 1) else { return false }
                } else if let additional = shape["additionalProperties"],
                          !matches(entry, schema: additional, depth: depth + 1) { return false }
            }
        }
        if let array = value.arrayValue {
            guard array.count <= 4096, bounded(Double(array.count), minimum: shape["minItems"], maximum: shape["maxItems"]) else { return false }
            if let items = shape["items"], !array.allSatisfy({ matches($0, schema: items, depth: depth + 1) }) { return false }
            if shape["uniqueItems"] == .bool(true) {
                for index in array.indices where array[..<index].contains(array[index]) { return false }
            }
        }
        if let string = value.stringValue {
            guard bounded(Double(string.unicodeScalars.count), minimum: shape["minLength"], maximum: shape["maxLength"]) else { return false }
            if let pattern = shape["pattern"]?.stringValue,
               string.range(of: pattern, options: .regularExpression) == nil { return false }
        }
        if let number = value.numberValue {
            guard number.isFinite, bounded(number, minimum: shape["minimum"], maximum: shape["maximum"]) else { return false }
            if let minimum = shape["exclusiveMinimum"]?.numberValue, number <= minimum { return false }
            if let maximum = shape["exclusiveMaximum"]?.numberValue, number >= maximum { return false }
            if let divisor = shape["multipleOf"]?.numberValue,
               divisor <= 0 || abs(number / divisor - (number / divisor).rounded()) > 1e-9 { return false }
        }
        return true
    }

    private static func bounded(_ number: Double, minimum: AIJSON?, maximum: AIJSON?) -> Bool {
        (minimum?.numberValue.map { number >= $0 } ?? true) && (maximum?.numberValue.map { number <= $0 } ?? true)
    }

    private static func hasType(_ value: AIJSON, _ type: String) -> Bool {
        switch type {
        case "object": value.objectValue != nil
        case "array": value.arrayValue != nil
        case "string": value.stringValue != nil
        case "number": value.numberValue?.isFinite == true
        case "integer": value.numberValue.map { $0.isFinite && $0.rounded() == $0 } == true
        case "boolean": value.boolValue != nil
        case "null": value == .null
        default: false
        }
    }
}
