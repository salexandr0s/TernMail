import MailStore
import SwiftUI

struct TriageControls: View {
    let mailbox: MailboxModel

    var body: some View {
        Menu {
            Button("Report Spam") { mailbox.triage.perform(.spam) }
            Button("Not Spam") { mailbox.triage.perform(.notSpam) }
            Divider()
            Button("Mark as Important") { mailbox.triage.perform(.important) }
            Button("Mark as Not Important") { mailbox.triage.perform(.notImportant) }
            Divider()
            Button("Mark All as Read") { mailbox.triage.markAllRead() }
                .disabled(mailbox.search.isActive || mailbox.selectedLabelID == MailboxModel.snoozedID || mailbox.selectedLabelID == MailboxModel.outboxID)
            if mailbox.selectedLabelID == SystemLabel.trash || mailbox.selectedLabelID == SystemLabel.spam {
                Button("Delete Forever…", role: .destructive) { Task { await mailbox.triage.preparePermanentDeletion() } }
                Button(mailbox.selectedLabelID == SystemLabel.trash ? "Empty Trash…" : "Delete All Spam…", role: .destructive) {
                    Task { await mailbox.triage.preparePermanentDeletion(entireMailbox: true) }
                }
            }
        } label: {
            Label("Mail Actions", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .disabled(mailbox.triage.isPreparing || mailbox.triage.isDeleting)
        .help("Spam, importance and mailbox actions")
        .accessibilityLabel("Mail Actions")
    }
}

/// Install once in the mail workspace so menus and swipe actions share review.
struct TriagePresentationHost: View {
    let mailbox: MailboxModel
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = mailbox.triage
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: $model.deletionReview) { review in DestructiveMailReview(model: model, review: review) }
            .sheet(item: $model.filterRequest) { request in SenderFilterReview(request: request, app: app) }
            .alert("Couldn't change mail", isPresented: $model.error.isPresent()) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

struct TriagePreferencesPane: View {
    @AppStorage(MailTriagePreferences.deleteKey) private var deleteBehavior = DeleteKeyBehavior.archive.rawValue
    @AppStorage(MailSounds.enabledKey) private var sounds = false

    var body: some View {
        SettingsPage {
            Section {
                Picker("Delete key", selection: $deleteBehavior) {
                    deletionChoice("Archive or remove the current label",
                        detail: "Keep the mail. In a custom label, remove that label from the selection.")
                        .tag(DeleteKeyBehavior.archive.rawValue)
                    deletionChoice("Move to Trash", detail: "Move the selected mail to Trash.")
                        .tag(DeleteKeyBehavior.trash.rawValue)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel("Delete key action")
                .padding(.vertical, Tokens.Space.s2)
            } header: {
                Label("Delete key", systemImage: "delete.left")
            } footer: {
                Text(deleteBehavior == DeleteKeyBehavior.trash.rawValue
                    ? "Pressing Delete moves the selection to Trash."
                    : "Pressing Delete archives the selection, or removes the custom label you are viewing.")
            }
            Section("Sound") {
                SettingsToggleRow("Play mail sounds", detail: "Use macOS sounds for archive, Trash and sent mail.", isOn: $sounds)
            }
        }
    }

    private func deletionChoice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(title).font(.body.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Tokens.Space.s1)
    }
}
