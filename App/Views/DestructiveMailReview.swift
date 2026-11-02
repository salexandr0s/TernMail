import SwiftUI

struct DestructiveMailReview: View {
    @Bindable var model: MailTriageModel
    let review: MailDeletionReview
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsEditorSheet(title: review.title, width: Tokens.Settings.editorWideWidth,
                            messages: model.error.map { [$0] } ?? []) {
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    Label("Permanently delete \(review.count) \(review.count == 1 ? "message" : "messages")?",
                          systemImage: "trash")
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("These messages cannot be recovered. Messages that arrive after this review are excluded; any message moved out of Spam or Trash will be kept.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    Text("Accounts").font(.callout.bold()).foregroundStyle(.secondary)
                    ForEach(review.approvals) { approval in
                        let email = app.mailbox?.account(id: approval.accountID)?.account.email ?? "Account removed"
                        LabeledContent {
                            Text(approval.count.formatted())
                                .monospacedDigit()
                        } label: {
                            Text(email)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(email)
                        }
                        .font(.callout)
                    }
                }
                .padding(Tokens.Space.s4)
                .ternSurface(style: .grouped)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mail.deletion.accounts")

                Text("Google's full mail permission is required. If needed, Google will ask before deletion queues.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if model.isDeleting { ProgressView().controlSize(.small).accessibilityLabel("Deleting messages") }
            // Return keeps the mail. Deleting for good takes a click.
            Button("Cancel") { model.deletionReview = nil }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isDeleting)
                .accessibilityIdentifier("mail.deletion.cancel")
            Button("Delete Forever", role: .destructive) { Task { await model.deleteReviewedMessages(using: app) } }
                .disabled(model.isDeleting)
                .accessibilityIdentifier("mail.deletion.confirm")
        }
        .interactiveDismissDisabled(model.isDeleting)
        .onExitCommand { if !model.isDeleting { model.deletionReview = nil } }
    }
}
