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
    private var statusColor: Color {
        isComplete ? Tokens.Status.success : needsAttention ? Tokens.Status.warning : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            HStack(alignment: .top, spacing: Tokens.Space.s4) {
                Image(systemName: isComplete ? "checkmark.icloud.fill" : needsAttention ? "exclamationmark.icloud" : "icloud.and.arrow.up")
                    .font(.title).foregroundStyle(statusColor)
                    .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                    .background(statusColor.opacity(Tokens.Opacity.wash),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let delivery {
                deliveryProgress(delivery)
            } else if !isComplete {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel(phase == .applying ? "Preparing Gmail changes" : "Checking Gmail delivery")
            }
            if let receipt {
                Divider()
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text("Your selection").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Label("\(receipt.categoryCount) \(receipt.categoryCount == 1 ? "label" : "labels") · \(receipt.messageCount) \(receipt.messageCount == 1 ? "message" : "messages")",
                          systemImage: "tag")
                        .font(.callout.weight(.medium))
                    if receipt.filterCount > 0 {
                        Text("\(receipt.filterCount) sender \(receipt.filterCount == 1 ? "rule" : "rules") \(isComplete ? "will label future incoming mail." : "included for future incoming mail.")")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if phase != .applying {
                Divider()
                if isComplete {
                    Button("Done", action: onDone).buttonStyle(.borderedProminent)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Tokens.Space.s3) {
                            recoveryActions
                            Spacer(minLength: Tokens.Space.s3)
                            backToStart
                        }
                        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                            recoveryActions
                            backToStart
                        }
                    }
                }
            }
        }
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }

    private func deliveryProgress(_ delivery: OrganizationApplicationStatus) -> some View {
        let total = delivery.sentCount + delivery.pendingCount + delivery.failedCount + delivery.unconfirmedCount
        return VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Space.s16 + Tokens.Space.s8), alignment: .leading)],
                      alignment: .leading, spacing: Tokens.Space.s4) {
                statusCount(delivery.sentCount, title: "Saved", symbol: "checkmark.circle", color: Tokens.Status.success)
                if delivery.pendingCount > 0 {
                    statusCount(delivery.pendingCount, title: "Queued", symbol: "clock", color: .accentColor)
                }
                if delivery.failedCount > 0 {
                    statusCount(delivery.failedCount, title: "Need retry", symbol: "exclamationmark.circle", color: Tokens.Status.warning)
                }
                if delivery.unconfirmedCount > 0 {
                    statusCount(delivery.unconfirmedCount, title: "Unconfirmed", symbol: "questionmark.circle", color: .secondary)
                }
            }
            if !isComplete, total > 0 {
                ProgressView(value: Double(delivery.sentCount), total: Double(total))
                    .accessibilityLabel("Gmail delivery")
                    .accessibilityValue("\(delivery.sentCount) of \(total) changes saved")
            }
            if delivery.failedCount > 0 {
                SettingsNote("Review failed changes to retry the remaining labels and rules.", systemImage: "exclamationmark.circle")
            }
            if delivery.unconfirmedCount > 0 {
                SettingsNote("Some changes couldn't be confirmed. Check this account's labels and filters in Gmail.",
                             systemImage: "questionmark.circle")
            }
        }
    }

    private func statusCount(_ count: Int, title: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(count, format: .number).font(.title.bold()).monospacedDigit()
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) changes: \(title.lowercased())")
    }

    private var recoveryActions: some View {
        HStack(spacing: Tokens.Space.s3) {
            if (delivery?.failedCount ?? 0) > 0 {
                Button("Review failed changes", action: onOpenFailedChanges)
                    .buttonStyle(.borderedProminent)
            }
            Button("Check status", systemImage: "arrow.clockwise", action: onCheck)
        }
    }

    private var backToStart: some View {
        Button("Back to start", action: onDone).buttonStyle(.borderless)
            .help("Queued changes remain in the delivery queue.")
    }

    private var title: String {
        if isComplete { return "Your labels are in Gmail" }
        if needsAttention { return "Some changes need attention" }
        return phase == .applying ? "Preparing your changes" : "Changes queued for Gmail"
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
        return "You can leave this page. Tern continues saving queued changes when this account is online."
    }
}
