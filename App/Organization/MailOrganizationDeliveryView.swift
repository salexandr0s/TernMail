import SwiftUI
import SyncEngine

struct MailOrganizationDeliveryView: View {
    let phase: MailOrganizationModel.Phase
    let receipt: OrganizationApplicationReceipt?
    let delivery: OrganizationApplicationStatus?
    let onCheck: () -> Void
    let onOpenFailedChanges: () -> Void
    let onDone: () -> Void

    private var isComplete: Bool { delivery?.isComplete == true }
    private var needsAttention: Bool {
        (delivery?.failedCount ?? 0) > 0 || (delivery?.unconfirmedCount ?? 0) > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            HStack(alignment: .top, spacing: Tokens.Space.s4) {
                Image(systemName: isComplete ? "checkmark.icloud.fill" : needsAttention ? "exclamationmark.icloud" : "icloud.and.arrow.up")
                    .font(.title)
                    .foregroundStyle(isComplete ? Tokens.Status.success : needsAttention ? Tokens.Status.warning : Color.accentColor)
                    .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !isComplete {
                if let delivery {
                    let total = delivery.sentCount + delivery.pendingCount + delivery.failedCount + delivery.unconfirmedCount
                    if total > 0 {
                        ProgressView(value: Double(delivery.sentCount), total: Double(total))
                            .accessibilityLabel("Gmail delivery")
                            .accessibilityValue("\(delivery.sentCount) of \(total) changes saved")
                        Text("\(delivery.sentCount) of \(total) changes saved")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if delivery.failedCount > 0 {
                        Label("\(delivery.failedCount) \(delivery.failedCount == 1 ? "change needs" : "changes need") a retry. Review them in Failed Changes.",
                              systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(Tokens.Status.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if delivery.unconfirmedCount > 0 {
                        Text("Some changes couldn't be confirmed. Check this account's labels and filters in Gmail.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ProgressView().progressViewStyle(.linear)
                        .accessibilityLabel("Preparing Gmail changes")
                }
            }
            if let receipt {
                Label("\(receipt.categoryCount) \(receipt.categoryCount == 1 ? "label" : "labels") · \(receipt.messageCount) \(receipt.messageCount == 1 ? "message" : "messages")",
                      systemImage: "tag")
                    .font(.callout.weight(.medium))
                if receipt.filterCount > 0 {
                    Text("\(receipt.filterCount) sender \(receipt.filterCount == 1 ? "rule" : "rules") \(isComplete ? "will label future incoming mail." : "included for future incoming mail.")")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if phase != .applying {
                HStack(spacing: Tokens.Space.s3) {
                    if isComplete {
                        Button("Done", action: onDone).buttonStyle(.borderedProminent)
                    } else {
                        if (delivery?.failedCount ?? 0) > 0 {
                            Button("Review failed changes", action: onOpenFailedChanges)
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Check status", systemImage: "arrow.clockwise", action: onCheck)
                        Spacer(minLength: 0)
                        Button("Back to start", action: onDone)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }

    private var title: String {
        if isComplete { return "Your labels are in Gmail" }
        if needsAttention { return "Some changes need attention" }
        return phase == .applying ? "Preparing your changes" : "Saving to Gmail"
    }

    private var detail: String {
        if isComplete { return "Your selected messages are organized. You can inspect the labels and examples below." }
        if phase == .applying { return "Checking your selection and preparing the labels and rules." }
        if let delivery, delivery.pendingCount == 0 {
            if delivery.unconfirmedCount > 0 {
                return "Gmail delivery couldn't be confirmed for every change. Check this account in Gmail before starting again."
            }
            if delivery.failedCount > 0 {
                return "The remaining changes need a retry in Failed Changes."
            }
        }
        return "Your changes are queued. You can leave this page; Tern continues saving them when this account is online."
    }
}
