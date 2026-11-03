import Foundation

/// Decides whether the compose window may close. A draft that closing
/// would store goes first, and the window closes once that worked. A store
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
