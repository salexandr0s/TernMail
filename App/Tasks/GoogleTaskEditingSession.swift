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
    private let originalNotes: GoogleTaskNotes
    @ObservationIgnored private var creation = TaskCreationRequest(title: "")

    init(model: GoogleTasksModel, context: GoogleTaskEditorContext) {
        self.model = model
        self.context = context
        let originalNotes = GoogleTaskNotes(context.task?.notes ?? "")
        self.originalNotes = originalNotes
        title = context.task?.title ?? ""
        notes = originalNotes.text
        hasDueDate = context.task?.dueDay != nil
        dueDate = context.task?.dueDay.flatMap { GoogleTaskDateCoding.date($0) } ?? .now
    }

    var canSave: Bool { !isSaving && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // An untouched notes field must not rewrite the provider's formatting.
        let savedNotes = notes == originalNotes.text ? (context.task?.notes ?? "") : originalNotes.replacingText(notes)
        guard !trimmed.isEmpty, trimmed.count <= 1024, savedNotes.count <= 8192 else {
            error = "Use a title under 1,024 characters and notes under 8,192 characters."
            return false
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let newDue = hasDueDate ? GoogleTaskDateCoding.string(dueDate) : nil
        let saved: Bool
        if let task = context.task {
            let change: GoogleTaskDueChange = newDue == task.dueDay ? .unchanged : newDue.map(GoogleTaskDueChange.set) ?? .clear
            let update = GoogleTaskUpdate(title: trimmed == task.title ? nil : trimmed,
                notes: savedNotes == (task.notes ?? "") ? nil : savedNotes, due: change)
            guard update != GoogleTaskUpdate() else { return true }
            saved = await model.update(task, update: update, location: context.location)
        } else {
            creation.title = trimmed
            creation.notes = notes
            creation.dueDate = newDue
            creation.accountID = context.location.accountID
            creation.listID = context.location.listID
            saved = await model.add(creation)
        }
        if !saved { error = model.errorMessage ?? "The task couldn't be saved. Check your connection and try again." }
        return saved
    }
}
