extension SearchQuery {
    /// `value` in double quotes, so an operator such as `label:` or `from:` takes it as one operand.
    /// Backslashes and quotes inside are escaped with a backslash.
    public static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
