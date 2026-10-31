import AppKit

extension NSPasteboard {
    /// Replaces everything on the pasteboard with plain text, as a Copy command does.
    func replaceContents(with string: String) {
        clearContents()
        setString(string, forType: .string)
    }
}
