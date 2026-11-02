import GmailAPI
import SwiftUI

struct GoogleTaskConflictReview: View {
    let session: GoogleTaskEditingSession

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Label("This task changed in Google Tasks", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.callout.weight(.medium))
            Text("Your edits are still above. Review the latest version before saving again.")
                .font(.caption).foregroundStyle(.secondary)
            if let task = session.latestTask {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Google's latest version").font(.caption).foregroundStyle(.secondary)
                    Text(task.title).font(.callout).textSelection(.enabled)
                    let notes = GoogleTaskNotes(task.notes ?? "").text
                    if !notes.isEmpty {
                        ScrollView { Text(notes).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(maxHeight: Tokens.Space.s16 + Tokens.Space.s8)
                    }
                    Text(task.isCompleted ? "Completed" : "Needs action").font(.caption)
                    if let day = task.dueDay, let date = GoogleTaskDateCoding.date(day) {
                        Text("Due: \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                    } else {
                        Text("No due date").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { choices }
                    VStack(alignment: .leading) { choices }
                }
                Text("Keep My Changes retains the fields you edited and uses Google's other changes. Save when you're ready.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Refresh Review") { Task { await session.reloadConflict() } }
                    .disabled(session.isLoadingConflict)
            }
            if session.isLoadingConflict { ProgressView("Loading latest task…").controlSize(.small) }
        }
        .padding(Tokens.Space.s3)
        .background(Tokens.Status.warning.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("google-task-conflict-review")
    }

    private var choices: some View {
        Group {
            Button("Use Google Version", action: session.useGoogleVersion)
            Button("Keep My Changes", action: session.keepMyChanges)
        }
        .controlSize(.small)
        .disabled(session.isSaving || session.isLoadingConflict)
    }
}
