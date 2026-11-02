import MailStore
import SwiftUI

/// A receipt reports display by the recipient's app. No receipt leaves the
/// outcome unknown, including when that app does not support receipt requests.
struct ReadReceiptBadge: View {
    let accountID: String
    let rfcMessageID: String
    let cache: MailCache
    @State private var status: ReadReceiptStatus?
    @State private var showsDetails = false

    private var requestID: String { "\(accountID.utf8.count):\(accountID)\(rfcMessageID)" }
    private var receivedCount: Int { status?.recipients.filter { $0.receivedAt != nil }.count ?? 0 }

    var body: some View {
        Group {
            if let status {
                Button { showsDetails = true } label: {
                    Label(ReadReceiptDetails.summary(for: status),
                          systemImage: receivedCount > 0 ? "checkmark.envelope" : "envelope.badge")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Show read receipt details")
                .accessibilityIdentifier("read-receipt-\(rfcMessageID)")
                .popover(isPresented: $showsDetails) {
                    ReadReceiptDetails(status: status)
                }
            }
        }
        .task(id: requestID) {
            status = nil
            showsDetails = false
            do {
                for try await value in cache.observeReadReceiptStatus(accountID: accountID, rfcMessageID: rfcMessageID) {
                    guard !Task.isCancelled else { return }
                    status = value
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = nil
            }
        }
    }
}

struct ReadReceiptDetails: View {
    let status: ReadReceiptStatus

    static func summary(for status: ReadReceiptStatus) -> String {
        summary(for: status.recipients)
    }

    static func summary(for recipients: [ReadReceiptRecipientStatus]) -> String {
        let received = recipients.filter { $0.receivedAt != nil }.count
        guard received > 0 else {
            return recipients.count > 1 ? "\(recipients.count.formatted()) receipts requested" : "Receipt requested"
        }
        guard recipients.count > 1 else { return "Read receipt received" }
        return "\(received.formatted()) of \(recipients.count.formatted()) receipts received"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "envelope.badge")
                    .font(.title3).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Space.s10, height: Tokens.Space.s10)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Read receipts").font(.headline)
                    Text(Self.summary(for: status)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Tokens.Space.s4)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    ForEach(status.recipients) { recipient in
                        ReadReceiptRecipientRow(recipient: recipient)
                        if recipient.id != status.recipients.last?.id {
                            Divider().padding(.leading, Tokens.Control.icon + Tokens.Space.s2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Space.s4)
            }
            .frame(maxHeight: Tokens.Popover.maxListHeight)
            Divider()
            Text("Receipts depend on the recipient's email app and settings. No receipt means the outcome is unknown. Dates show when receipts arrived.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Tokens.Space.s4)
                .background(Tokens.Surface.muted.opacity(Tokens.Opacity.disabled))
        }
        .frame(width: Tokens.Popover.width)
        .frame(maxHeight: Tokens.Analytics.popoverMaxHeight)
    }
}

struct ReadReceiptRecipientRow: View {
    let recipient: ReadReceiptRecipientStatus

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Image(systemName: recipient.receivedAt == nil ? "clock" : "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(recipient.receivedAt == nil ? Color.secondary : Tokens.Status.success)
                .frame(width: Tokens.Control.icon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(recipient.address).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = recipient.receivedAt {
                    Text("Receipt received \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Receipt arrived \(date.formatted(date: .complete, time: .shortened))")
                } else {
                    Text("No receipt yet").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
