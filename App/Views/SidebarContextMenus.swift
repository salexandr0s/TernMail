import GmailAPI
import MailStore
import SwiftUI

/// Mailbox actions retain the row's scope even when another mailbox is selected.
struct MailboxContextMenu: View {
    let mailbox: MailboxModel
    let box: MailboxID
    var favoriteTarget: MailFavoriteTarget?

    var body: some View {
        Button("Mark All as Read", systemImage: "envelope.open") { mailbox.triage.markAllRead(in: box) }
            .disabled(!MailTriageModel.canMarkAllRead(box))
        if box.id == SystemLabel.trash || box.id == SystemLabel.spam {
            Button(box.id == SystemLabel.trash ? "Empty Trash…" : "Delete All Spam…", systemImage: "trash.slash", role: .destructive) {
                Task { await mailbox.triage.preparePermanentDeletion(entireMailbox: true, in: box) }
            }
            .disabled(mailbox.triage.isPreparing || mailbox.triage.isDeleting)
        }
        if let favoriteTarget {
            FavoriteMembershipButton(navigation: mailbox.navigation, target: favoriteTarget)
        }
    }
}

struct FavoriteMembershipButton: View {
    let navigation: MailNavigationModel
    let target: MailFavoriteTarget

    var body: some View {
        Group {
            if let favorite = navigation.favorites.first(where: { $0.target.matchesFavorite(target) }) {
                Button("Remove from Favorites", systemImage: "star.slash") {
                    Task { await navigation.removeFavorite(favorite.id) }
                }
            } else {
                Button("Add to Favorites", systemImage: "star") {
                    Task { await navigation.addFavorite(target) }
                }
            }
        }
        .disabled(navigation.isSaving)
    }
}

struct LabelContextMenu: View {
    let mailbox: MailboxModel
    let label: LabelRecord
    var showsFavoriteAction = true

    var body: some View {
        Group {
            MailboxContextMenu(mailbox: mailbox, box: .account(label.accountID, label.id),
                favoriteTarget: showsFavoriteAction ? .label(accountID: label.accountID, labelID: label.id) : nil)
            Divider()
            Picker("Show in Sidebar", selection: Binding(
                get: { LabelListVisibility(rawValue: label.labelListVisibility ?? "") ?? .show },
                set: { mailbox.setLabelVisibility(label, to: $0) }
            )) {
                ForEach(LabelListVisibility.allCases, id: \.rawValue) { visibility in
                    Text(visibility.sidebarTitle).tag(visibility)
                }
            }
            .pickerStyle(.menu)
            Button("New Nested Label…", systemImage: "plus") { mailbox.showNewNestedLabel(under: label) }
            Button("Edit Label…", systemImage: "pencil") { mailbox.showEditLabel(label) }
            Button("Delete Label…", systemImage: "trash", role: .destructive) { mailbox.labelToDelete = label }
        }
        .disabled(LabelRules.isTemporary(label.id))
    }
}

struct SavedSearchContextMenu: View {
    let mailbox: MailboxModel
    let search: SavedMailSearch
    var showsFavoriteAction = true

    var body: some View {
        if showsFavoriteAction {
            FavoriteMembershipButton(navigation: mailbox.navigation, target: .savedSearch(id: search.id))
        }
        Button("Edit Saved Search…", systemImage: "pencil") { mailbox.navigation.searchToEdit = search }
        Button("Delete Saved Search", systemImage: "trash", role: .destructive) {
            Task { await mailbox.navigation.deleteSearch(search.id) }
        }
        .disabled(mailbox.navigation.isSaving)
    }
}

extension MailboxModel {
    func showNewNestedLabel(under parent: LabelRecord) {
        guard !parent.isSystem, !LabelRules.isTemporary(parent.id),
              account(id: parent.accountID)?.labels.contains(where: { $0.id == parent.id }) == true else { return }
        labelEdit = nil
        labelEditor = LabelEditorRequest(accountID: parent.accountID, kind: .new(applyingTo: []),
            draft: .init(name: "", parent: parent.name, color: nil))
    }
}
