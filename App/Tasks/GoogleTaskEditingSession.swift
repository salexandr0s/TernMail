import Foundation
import GmailAPI
import Observation

@MainActor @Observable
final class GoogleTaskEditingSession {
    let model: GoogleTasksModel
    let context: GoogleTaskEditorContext
    var title: String
    var notes: String
    var hasDueDate: Bool
    var dueDate: Date
    var isSaving = false
    var error: String?
    private(set) var needsConflictReview = false
    private(set) var latestTask: GoogleTask?
    private(set) var isLoadingConflict = false
    private var baseline: GoogleTask?
    private var originalNotes: GoogleTaskNotes
    @ObservationIgnored private var creation = TaskCreationRequest(title: "")

    init(model: GoogleTasksModel, context: GoogleTaskEditorContext) {
        self.model = model
        self.context = context
        baseline = context.task
        let originalNotes = GoogleTaskNotes(context.task?.notes ?? "")
        self.originalNotes = originalNotes
        title = context.task?.title ?? ""
        notes = originalNotes.text
        hasDueDate = context.task?.dueDay != nil
        dueDate = context.task?.dueDay.flatMap { GoogleTaskDateCoding.date($0) } ?? .now
    }

    var canSave: Bool { !isSaving && !needsConflictReview && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @discardableResult
    func save() async -> Bool {
        guard !isSaving, !needsConflictReview else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // An untouched notes field must not rewrite the provider's formatting.
        let savedNotes = notes == originalNotes.text ? (baseline?.notes ?? "") : originalNotes.replacingText(notes)
        guard !trimmed.isEmpty, trimmed.count <= 1024, savedNotes.count <= 8192 else {
            error = "Use a title under 1,024 characters and notes under 8,192 characters."
            return false
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let newDue = hasDueDate ? GoogleTaskDateCoding.string(dueDate) : nil
        let saved: Bool
        if let task = baseline {
            let change: GoogleTaskDueChange = newDue == task.dueDay ? .unchanged : newDue.map(GoogleTaskDueChange.set) ?? .clear
            let update = GoogleTaskUpdate(title: trimmed == task.title ? nil : trimmed,
                notes: savedNotes == (task.notes ?? "") ? nil : savedNotes, due: change)
            guard update != GoogleTaskUpdate() else { return true }
            saved = await model.update(task, update: update, location: context.location) { self.needsConflictReview = true }
        } else {
            creation.title = trimmed
            creation.notes = notes
            creation.dueDate = newDue
            creation.accountID = context.location.accountID
            creation.listID = context.location.listID
            saved = await model.add(creation)
        }
        if !saved { error = model.errorMessage ?? "The task couldn't be saved. Check your connection and try again." }
        if needsConflictReview { await reloadConflict() }
        return saved
    }

    func reloadConflict() async {
        guard needsConflictReview, !isLoadingConflict, let baseline else { return }
        isLoadingConflict = true
        defer { isLoadingConflict = false }
        do {
            latestTask = try await model.taskForReview(id: baseline.id, location: context.location)
            error = nil
        } catch {
            latestTask = nil
            self.error = "The latest task could not be loaded. Your edits are still here. Try refreshing the review."
        }
    }

    func useGoogleVersion() {
        guard let latestTask else { return }
        adopt(latestTask, keepingChanges: false)
    }

    func keepMyChanges() {
        guard let latestTask else { return }
        adopt(latestTask, keepingChanges: true)
    }

    private func adopt(_ task: GoogleTask, keepingChanges: Bool) {
        let previous = baseline
        let localDue = hasDueDate ? GoogleTaskDateCoding.string(dueDate) : nil
        if !keepingChanges || title == previous?.title { title = task.title }
        if !keepingChanges || notes == originalNotes.text { notes = GoogleTaskNotes(task.notes ?? "").text }
        if !keepingChanges || localDue == previous?.dueDay {
            hasDueDate = task.dueDay != nil
            dueDate = task.dueDay.flatMap { GoogleTaskDateCoding.date($0) } ?? .now
        }
        baseline = task
        originalNotes = GoogleTaskNotes(task.notes ?? "")
        latestTask = nil
        needsConflictReview = false
        error = nil
    }
}
