extension SearchQuery {
    /// `value` in double quotes, so an operator such as `label:` or `from:` takes it as one operand.
    /// Gmail's syntax has no escapes, so a value containing a double quote has no quoted form.
    public static func quoted(_ value: String) -> String? {
        value.contains("\"") ? nil : "\"" + value + "\""
    }
}
