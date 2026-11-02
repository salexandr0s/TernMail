import GmailAPI
import SwiftUI

struct GoogleTaskConflictReview: View {
    let session: GoogleTaskEditingSession

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Label("This task changed in Google Tasks", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.headline)
            Text("Your edits are still above. Review the latest version before saving again.")
                .font(.callout).foregroundStyle(.secondary)
            if let task = session.latestTask {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text("Google's latest version").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(task.title).font(.body.bold()).textSelection(.enabled)
                    let notes = GoogleTaskNotes(task.notes ?? "").text
                    if !notes.isEmpty {
                        ScrollView { Text(notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(maxHeight: Tokens.Space.s16 + Tokens.Space.s8)
                    }
                    Divider()
                    Label(task.isCompleted ? "Completed" : "Needs action",
                          systemImage: task.isCompleted ? "checkmark.circle" : "circle")
                        .font(.callout)
                    if let day = task.dueDay, let date = GoogleTaskDateCoding.date(day) {
                        Label("Due: \(date.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                            .font(.callout)
                    } else {
                        Text("No due date").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(Tokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ternSurface(radius: Tokens.Radius.md)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Space.s2) { choices }
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) { choices }
                }
                Text("Keep My Changes retains the fields you edited and uses Google's other changes. Save when you're ready.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Refresh Review") { Task { await session.reloadConflict() } }
                    .disabled(session.isLoadingConflict)
            }
            if session.isLoadingConflict { ProgressView("Loading latest task…").controlSize(.small) }
        }
        .padding(Tokens.Space.s3)
        .background(Tokens.Status.warning.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("google-task-conflict-review")
    }

    private var choices: some View {
        Group {
            Button("Use Google Version", action: session.useGoogleVersion)
                .fixedSize()
                .accessibilityIdentifier("google-task-conflict-use-google")
            Button("Keep My Changes", action: session.keepMyChanges)
                .fixedSize()
                .accessibilityIdentifier("google-task-conflict-keep-mine")
        }
        .buttonStyle(.bordered)
        .disabled(session.isSaving || session.isLoadingConflict)
    }
}
