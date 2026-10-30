import SwiftUI

struct DestructiveMailReview: View {
    @Bindable var model: MailTriageModel
    let review: MailDeletionReview
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Label(review.title, systemImage: "trash.fill").font(.title2.weight(.semibold))
            Text("Permanently delete \(review.count) \(review.count == 1 ? "message" : "messages")?")
                .font(.headline)
            Text("These messages cannot be recovered. Messages that arrive after this review are excluded; any message moved out of Spam or Trash will be kept.")
                .foregroundStyle(.secondary)
            ForEach(review.approvals) { approval in
                let email = app.mailbox?.account(id: approval.accountID)?.account.email ?? "Account removed"
                HStack { Text(email); Spacer(); Text(approval.count.formatted()).monospacedDigit() }
                    .font(.callout)
            }
            Text("Google's full mail permission is required. If needed, Google will ask before deletion queues.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isDeleting { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { model.deletionReview = nil }.keyboardShortcut(.cancelAction)
                    .disabled(model.isDeleting)
                Spacer()
                Button("Delete Forever", role: .destructive) { Task { await model.deleteReviewedMessages(using: app) } }
                    .disabled(model.isDeleting).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Space.s6)
        .frame(width: Tokens.Sheet.smallWidth)
        .interactiveDismissDisabled(model.isDeleting)
    }
}
