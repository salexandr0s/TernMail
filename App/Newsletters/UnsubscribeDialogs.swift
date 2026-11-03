import MailStore
import SwiftUI

struct UnsubscribeConfirmationView: View {
    @Bindable var model: UnsubscribeModel
    let confirmation: UnsubscribeConfirmation

    private var count: Int { confirmation.subscriptions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Image(systemName: "minus.circle")
                    .font(.title2).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Control.avatarLarge, height: Tokens.Control.avatarLarge)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(count == 1 ? "Unsubscribe from this newsletter?" : "Unsubscribe from \(count) newsletters?")
                        .font(.title2.weight(.semibold))
                    Text(count == 1 ? "Send an unsubscribe request to this sender." : "Send an unsubscribe request to each sender.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    ForEach(confirmation.subscriptions) { subscription in
                        HStack(spacing: Tokens.Space.s3) {
                            AddressAvatar(accountID: subscription.accountID, address: subscription.senderAddress,
                                name: subscription.displayName)
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(subscription.displayName).fontWeight(.medium).lineLimit(1)
                                Text(subscription.listID ?? subscription.senderAddress)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Text(model.accountTitle(for: subscription.accountID))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(Tokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Tokens.Settings.pickerWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .ternOutline(radius: Tokens.Radius.md)
            Label("Existing emails stay in your mailbox. Senders may take a few days to stop new messages.", systemImage: "tray")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if confirmation.subscriptions.contains(where: { $0.status == .failed }) {
                Label("An earlier request may already have reached a sender. Continuing sends another request.",
                    systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Tokens.Space.s3) {
                Spacer(minLength: 0)
                Button("Cancel") { model.confirmation = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("unsubscribe.cancelConfirmation")
                Button(count == 1 ? "Unsubscribe" : "Unsubscribe from \(count)", action: model.confirmUnsubscribe)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("unsubscribe.confirm")
                    .disabled(model.isWorking || count == 0)
            }
        }
        .padding(Tokens.Space.s6)
        .frame(width: Tokens.Settings.editorWidth)
        .background(Tokens.Surface.muted)
    }
}

struct UnsubscribeManualView: View {
    @Bindable var model: UnsubscribeModel
    let subscription: NewsletterSubscription
    @State private var isOpening = false
    @State private var isCompleting = false

    private var current: NewsletterSubscription {
        model.subscriptions.first { $0.id == subscription.id } ?? subscription
    }
    private var usesWebsite: Bool { current.unsubscribeURL != nil }
    private var hasOpened: Bool { current.status == .opened }
    private var isBusy: Bool { isOpening || isCompleting }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                AddressAvatar(accountID: current.accountID, address: current.senderAddress,
                    name: current.displayName, size: Tokens.Control.avatarLarge)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(current.displayName).font(.title2.weight(.semibold)).lineLimit(2)
                    Text(current.listID ?? current.senderAddress)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Text(usesWebsite ? "Finish on the sender’s website" : "Unsubscribe by email")
                    .font(.headline)
                Text(usesWebsite
                    ? "This newsletter needs a visit to its unsubscribe page. Follow the sender’s instructions, then return here to mark it completed."
                    : "Tern will prepare an email from the receiving account. Review and send it, then return here to mark this newsletter completed.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Label(model.accountTitle(for: current.accountID), systemImage: "tray")
                    if let host = current.unsubscribeURL?.host {
                        Label(host, systemImage: "arrow.up.right.square")
                    } else {
                        Label("A draft opens for your review", systemImage: "square.and.pencil")
                    }
                }
                .font(.callout)
                .padding(Tokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .ternOutline(radius: Tokens.Radius.md)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Tokens.Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasOpened {
                Label(usesWebsite ? "Mark completed after the sender confirms your unsubscribe."
                    : "Mark completed after you send the unsubscribe email.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Tokens.Space.s3) {
                Button {
                    isOpening = true
                    Task { await model.openManualLink(); isOpening = false }
                } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        if isOpening { ProgressView().controlSize(.small) }
                        Label(usesWebsite ? "Open unsubscribe page" : "Prepare unsubscribe email",
                            systemImage: usesWebsite ? "arrow.up.right.square" : "square.and.pencil")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy || model.isUnavailable(current))
                .accessibilityIdentifier("unsubscribe.openManual")
                HStack(spacing: Tokens.Space.s3) {
                    Button("Close") { model.manualSubscription = nil }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isBusy)
                    Spacer(minLength: 0)
                    Button("I’ve unsubscribed") {
                        isCompleting = true
                        Task { await model.markManualComplete(); isCompleting = false }
                    }
                    .disabled(!hasOpened || isBusy || model.isUnavailable(current))
                    .accessibilityIdentifier("unsubscribe.completeManual")
                }
            }
        }
        .padding(Tokens.Space.s6)
        .frame(width: Tokens.Settings.editorWidth)
        .background(Tokens.Surface.muted)
    }
}
