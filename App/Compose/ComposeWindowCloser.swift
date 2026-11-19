import Foundation

/// Decides whether the compose window may close. A draft with changes Gmail
/// lacks is saved first, and the window closes once that worked. A save
/// that fails keeps the window open with the error and the draft.
@MainActor
final class ComposeWindowCloser {
    /// The model of the draft the window shows, which changes when the message moves to another account.
    weak var model: ComposeModel?

    func shouldClose() -> Bool {
        guard let model, !model.closesAtOnce else { return true }
        Task { await model.requestClose() }
        return false
    }
}
