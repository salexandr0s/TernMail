import GmailAPI
import SwiftUI

struct GoogleTaskEditorContext: Identifiable {
    let id = UUID()
    let task: GoogleTask?
    let location: GoogleTaskLocation
    let listTitle: String
}

struct GoogleTaskEditor: View {
    let model: GoogleTasksModel
    let context: GoogleTaskEditorContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var isSaving = false
    @State private var creation = TaskCreationRequest(title: "")
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(model: GoogleTasksModel, context: GoogleTaskEditorContext) {
        self.model = model
        self.context = context
        _title = State(initialValue: context.task?.title ?? "")
        _notes = State(initialValue: GoogleTaskNotes(context.task?.notes ?? "").text)
        _hasDueDate = State(initialValue: context.task?.dueDay != nil)
        _dueDate = State(initialValue: context.task?.dueDay.flatMap { GoogleTaskDateCoding.date($0) } ?? .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(context.task == nil ? "New task" : "Edit task").font(.title2.weight(.semibold))
                Label(context.listTitle, systemImage: "list.bullet").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                    Text("Title").font(.caption).foregroundStyle(.secondary)
                    TextField("What needs to be done?", text: $title, axis: .vertical)
                        .font(.body.weight(.medium)).textFieldStyle(.plain)
                        .lineLimit(2...4).focused($titleFocused)
                        .accessibilityLabel("Task title")
                        .accessibilityIdentifier("google-task-title")
                }
                Divider()
                VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextField("Add details", text: $notes, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(3...8)
                        .accessibilityLabel("Task notes")
                        .accessibilityIdentifier("google-task-notes")
                }
            }
            .padding(Tokens.Space.s3)
            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .ternOutline(radius: Tokens.Radius.md, style: .contrastOnly)
            .disabled(isSaving)
            HStack {
                Toggle("Due date", isOn: $hasDueDate).toggleStyle(.checkbox)
                Spacer(minLength: Tokens.Space.s3)
                if hasDueDate {
                    DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden()
                }
            }
            .disabled(isSaving)
            if let url = GoogleTaskRow.emailURL(context.task?.notes ?? "") {
                Button("Open Source Email", systemImage: "envelope") { openURL(url) }
                    .buttonStyle(.link)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Tokens.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(context.task == nil ? "Add Task" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(Tokens.Space.s5)
        .frame(width: Tokens.Sheet.smallWidth)
        .interactiveDismissDisabled(isSaving)
        .task { titleFocused = true }
    }

    private func save() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedNotes = GoogleTaskNotes(context.task?.notes ?? "").replacingText(notes)
        guard !trimmed.isEmpty, trimmed.count <= 1024, savedNotes.count <= 8192 else {
            error = "Use a title under 1,024 characters and notes under 8,192 characters."
            return
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let saved: Bool
        if let task = context.task {
            let newDue = hasDueDate ? GoogleTaskDateCoding.string(dueDate) : nil
            let change: GoogleTaskDueChange = newDue == task.dueDay ? .unchanged : newDue.map(GoogleTaskDueChange.set) ?? .clear
            saved = await model.update(task, update: GoogleTaskUpdate(title: trimmed == task.title ? nil : trimmed,
                notes: savedNotes == (task.notes ?? "") ? nil : savedNotes, due: change), location: context.location)
        } else {
            creation.title = trimmed
            creation.notes = notes
            creation.dueDate = hasDueDate ? GoogleTaskDateCoding.string(dueDate) : nil
            creation.accountID = context.location.accountID
            creation.listID = context.location.listID
            saved = await model.add(creation)
        }
        if saved { dismiss() }
        else { error = model.errorMessage ?? "The task couldn't be saved. Check your connection and try again." }
    }
}
