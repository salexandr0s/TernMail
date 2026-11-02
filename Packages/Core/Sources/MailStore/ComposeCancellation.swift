extension LocalDraft {
    /// A claimed action cannot be cancelled. Once a send request may have
    /// reached Gmail, its outcome must be reconciled before editing resumes.
    public func canCancelPendingExit(_ row: PendingAction) -> Bool {
        guard row.localDraftID == id, row.state == .queued else { return false }
        switch (state, row.kind) {
        case (.sending, .sendDraft): return !sendRequested
        case (.discarding, .discardDraft): return row.attempts == 0
        default: return false
        }
    }
}

extension DraftActivity {
    public var canCancelSend: Bool {
        isSending && rows.contains { draft.canCancelPendingExit($0) }
    }
}
