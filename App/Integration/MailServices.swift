import AppKit
import MessageContent

/// Tern's items in the Services menu of other apps. Each opens an editable
/// draft in its own window. A service never sends mail.
@MainActor
final class MailServices: NSObject {
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// New Tern Message with Selection: the selected text becomes the body.
    @objc(newMessageWithSelection:userData:error:)
    func newMessageWithSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = pasteboard.string(forType: .string), let request = Self.selectionRequest(from: text) else {
            error?.pointee = "The selection is empty." as NSString
            return
        }
        open(request, error: error)
    }

    /// New Tern Message to Address: the selected addresses go in To.
    @objc(newMessageToAddress:userData:error:)
    func newMessageToAddress(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = pasteboard.string(forType: .string), let request = Self.addressRequest(from: text) else {
            error?.pointee = "The selection has no email address." as NSString
            return
        }
        open(request, error: error)
    }

    /// A draft with the selected text as its body, or nil when only white space was selected.
    nonisolated static func selectionRequest(from text: String) -> MailtoRequest? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MailtoRequest(body: text.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    /// A draft to the addresses in the selection, which may carry names and be
    /// separated by commas, semicolons or new lines. Pieces that aren't
    /// addresses are left out, and nil means the selection had none.
    nonisolated static func addressRequest(from text: String) -> MailtoRequest? {
        let list = text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ";"))).joined(separator: ",")
        var seen = Set<String>()
        let addresses = EmailAddress.parseList(list).filter { $0.isValid && seen.insert($0.normalized).inserted }
        return addresses.isEmpty ? nil : MailtoRequest(to: addresses)
    }

    /// Brings the main window forward first, so a signed-out Tern shows its sign-in.
    private func open(_ request: MailtoRequest, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        app.showMainWindow()
        NSApp.activate()
        guard case .signedIn = app.phase, let mailbox = app.mailbox else {
            error?.pointee = "Sign in to Tern to write a message." as NSString
            return
        }
        Task {
            guard let id = await mailbox.startMailto(request), app.mailbox === mailbox else { return }
            app.mailURLs.composeDraftID = id
        }
    }
}
