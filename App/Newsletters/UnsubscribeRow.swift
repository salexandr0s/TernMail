import AppKit
import MailStore
import SwiftUI

struct UnsubscribeRow: View {
    let subscription: NewsletterSubscription
    let model: UnsubscribeModel
    let isCompact: Bool
    @State private var isHovered = false

    private var selected: Bool { model.selectedIDs.contains(subscription.id) }
    private var unavailable: Bool { model.isUnavailable(subscription) }
    private var hasNewMail: Bool {
        guard [.requested, .completed].contains(subscription.status), let date = subscription.statusDate else { return false }
        return subscription.latestDate > date
    }
    private var showsListID: Bool {
        subscription.listID != nil && model.subscriptions.contains {
            $0.id != subscription.id && $0.accountID == subscription.accountID
                && $0.senderAddress.caseInsensitiveCompare(subscription.senderAddress) == .orderedSame
        }
    }
    private var manualTitle: String {
        subscription.unsubscribeURL != nil ? "Unsubscribe on website" : "Unsubscribe by email"
    }
    private var manualSymbol: String { subscription.unsubscribeURL != nil ? "arrow.up.right.square" : "envelope" }
    private var selectionLabel: String {
        "Select \(subscription.displayName), \(model.accountTitle(for: subscription.accountID))"
            + (subscription.listID.map { ", list \($0)" } ?? "")
    }
    private var selectionHelp: String {
        if unavailable { return "Sign in again in Settings to manage this newsletter." }
        if model.isLoading { return "Wait for saved newsletters to finish loading." }
        if model.isWorking { return "Wait for the current request to finish." }
        switch subscription.status {
        case .requested: return "An unsubscribe request has already been sent."
        case .completed: return "This newsletter is marked completed."
        case .requesting: return "An unsubscribe request is being sent."
        case .opened: return "Finish unsubscribing on the website or by email."
        case .active, .failed:
            return subscription.oneClickURL == nil ? "Use the sender's website or email option to unsubscribe."
                : "Select this newsletter for batch unsubscribe."
        }
    }

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            UnsubscribeCheckbox(isOn: selected, isEnabled: model.isSelectable(subscription) && !model.isWorking,
                label: selectionLabel, identifier: "unsubscribe.select.\(subscription.id)", help: selectionHelp) {
                    model.toggleSelection(subscription)
                }
            AddressAvatar(accountID: subscription.accountID, address: subscription.senderAddress,
                name: subscription.displayName, size: Tokens.Control.avatarLarge)
            identity.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            activity
            actions.frame(width: Tokens.Control.iconButton * 2 + Tokens.Space.s1, alignment: .trailing)
        }
        .padding(.horizontal, Tokens.Space.s6)
        .padding(.vertical, isCompact ? Tokens.Space.s2 : Tokens.Space.s3)
        .frame(minHeight: Tokens.Space.s16 + (isCompact ? Tokens.Space.s2 : Tokens.Space.s4))
        .background(selected ? Color.accentColor.opacity(Tokens.Opacity.wash)
            : isHovered ? Color.primary.opacity(Tokens.Opacity.hover) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open latest message", systemImage: "envelope.open") { model.openLatestMessage(subscription) }
                .disabled(unavailable)
            if let listID = subscription.listID { Text("List: \(listID)") }
            if subscription.status == .active || subscription.status == .failed || subscription.status == .opened,
               subscription.unsubscribeURL != nil || subscription.mailtoURL != nil {
                Button(manualTitle + "…", systemImage: manualSymbol) { model.openSubscription(subscription) }
                    .disabled(unavailable || model.isWorking)
            }
            if subscription.status == .requested || subscription.status == .completed {
                Button("Move back to active", systemImage: "arrow.uturn.backward") {
                    Task { await model.resetStatus(subscription) }
                }
                .disabled(unavailable || model.isWorking)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unsubscribe.row.\(subscription.id)")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(spacing: Tokens.Space.s1_5) {
                Text(subscription.displayName).font(.body.weight(.semibold))
                    .lineLimit(1).help(subscription.displayName)
                if subscription.status == .failed {
                    statusIcon("exclamationmark.circle.fill", title: subscription.lastError ?? "Request needs attention",
                        tint: Tokens.Status.warning)
                } else if hasNewMail {
                    statusIcon("envelope.badge", title: "New mail since unsubscribe", tint: Tokens.Status.warning)
                } else if subscription.status == .opened {
                    statusIcon("clock", title: "Finish unsubscribing on the website or by email", tint: .secondary)
                }
            }
            if showsListID, let listID = subscription.listID {
                Label(listID, systemImage: "list.bullet")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help("Mailing list: \(listID). Latest message: \(subscription.latestSubject)")
            } else if !subscription.latestSubject.isEmpty {
                Button { model.openLatestMessage(subscription) } label: {
                    Text(subscription.latestSubject).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help("Open latest message: \(subscription.latestSubject)\(subscription.listID.map { "\nMailing list: " + $0 } ?? "")")
                .accessibilityLabel("Open latest message from \(subscription.displayName): \(subscription.latestSubject)")
                .disabled(unavailable)
            }
            HStack(spacing: Tokens.Space.s1_5) {
                Text(subscription.senderAddress)
                    .lineLimit(1).truncationMode(.middle).help(subscription.senderAddress)
                    .layoutPriority(1)
                if model.selectedAccountID.isEmpty && model.accounts.count > 1 {
                    Text("·").accessibilityHidden(true)
                    Text(model.accountTitle(for: subscription.accountID))
                        .lineLimit(1).truncationMode(.tail)
                        .help("Receiving account: \(model.accountTitle(for: subscription.accountID))")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var activity: some View {
        VStack(alignment: .trailing, spacing: Tokens.Space.s1_5) {
            HStack(spacing: Tokens.Space.s1_5) {
                Image(systemName: "envelope").font(.caption2).foregroundStyle(.secondary)
                Text(subscription.messageCount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                    .font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, Tokens.Space.s2)
            .padding(.vertical, Tokens.Space.s1)
            .background(Color.primary.opacity(Tokens.Opacity.hover), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            Text(subscription.latestDate, format: .dateTime.month(.abbreviated).day())
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
        .frame(minWidth: isCompact ? Tokens.Space.s16 : Tokens.Space.s16 + Tokens.Space.s4, alignment: .trailing)
        .help("\(subscription.messageCount.formatted()) newsletter emails found. Latest: \(subscription.latestDate.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(subscription.messageCount) newsletter emails found, latest \(subscription.latestDate.formatted(date: .abbreviated, time: .omitted))")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Tokens.Space.s1) {
            if unavailable {
                statusIcon("person.crop.circle.badge.exclamationmark", title: "Sign in again in Settings", tint: .secondary)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
            } else {
                switch subscription.status {
                case .requesting:
                    ProgressView().controlSize(.small)
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                        .accessibilityLabel("Sending unsubscribe request")
                case .requested, .completed:
                    UnsubscribeIconButton(symbol: "envelope.open", title: "Open latest message") { model.openLatestMessage(subscription) }
                    statusIcon(subscription.status == .requested ? "checkmark.circle" : "checkmark.circle.fill",
                        title: subscription.status == .requested ? "Unsubscribe request sent. Allow a few days." : "Unsubscribe marked completed",
                        tint: Tokens.Status.success)
                        .font(.title3)
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                case .active, .failed, .opened:
                    if subscription.status == .failed && subscription.oneClickURL != nil {
                        UnsubscribeIconButton(symbol: "arrow.clockwise", title: "Review unsubscribe request") {
                            model.proposeUnsubscribe(subscription)
                        }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("unsubscribe.action.\(subscription.id)")
                        if subscription.unsubscribeURL != nil || subscription.mailtoURL != nil {
                            UnsubscribeIconButton(symbol: manualSymbol, title: manualTitle) { model.openSubscription(subscription) }
                                .disabled(model.isWorking)
                                .accessibilityIdentifier("unsubscribe.fallback.\(subscription.id)")
                        }
                    } else {
                        UnsubscribeIconButton(symbol: "envelope.open", title: "Open latest message: \(subscription.latestSubject)") {
                            model.openLatestMessage(subscription)
                        }
                        if subscription.oneClickURL != nil && subscription.status != .opened {
                            UnsubscribeIconButton(symbol: "minus.circle", title: "Unsubscribe from \(subscription.displayName)", tint: .accentColor, emphasized: true) {
                                model.proposeUnsubscribe(subscription)
                            }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("unsubscribe.action.\(subscription.id)")
                        } else {
                            UnsubscribeIconButton(symbol: manualSymbol, title: "\(manualTitle): \(subscription.displayName)", tint: .accentColor, emphasized: true) {
                                model.openSubscription(subscription)
                            }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("unsubscribe.action.\(subscription.id)")
                        }
                    }
                }
            }
        }
    }

    private func statusIcon(_ symbol: String, title: String, tint: Color) -> some View {
        Image(systemName: symbol).foregroundStyle(tint)
            .help(title).accessibilityLabel(title)
    }
}

/// A compact native action with a stable hit target and a named keyboard control.
struct UnsubscribeIconButton: View {
    let symbol: String
    let title: String
    var tint: Color = .secondary
    var emphasized = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Control.icon))
                .foregroundStyle(isEnabled ? tint : .secondary)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.borderless)
        .background(fill, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .onHover { isHovered = $0 }
        .help(title).accessibilityLabel(title)
    }

    private var fill: Color {
        guard isEnabled else { return .clear }
        if emphasized { return tint.opacity(isHovered ? Tokens.Opacity.tint : Tokens.Opacity.wash) }
        return isHovered ? Color.primary.opacity(Tokens.Opacity.hover) : .clear
    }
}

extension NewsletterSubscription {
    var displayName: String {
        let name = senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? senderAddress : name
    }
}

/// Native checkboxes keep keyboard focus and the select-all mixed state aligned
/// with the rest of macOS. Selection remains owned by the page's model.
struct UnsubscribeCheckbox: NSViewRepresentable {
    let isOn: Bool
    var isMixed = false
    var isEnabled = true
    let label: String
    let identifier: String
    var help: String?
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator,
            action: #selector(Coordinator.toggle))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = isOn ? .on : isMixed ? .mixed : .off
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = help ?? label
        button.setAccessibilityHelp(help)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: Tokens.Space.s6, height: Tokens.Space.s6)
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func toggle() { action() }
    }
}
