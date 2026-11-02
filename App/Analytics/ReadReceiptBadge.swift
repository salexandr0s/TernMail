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
        let received = status.recipients.filter { $0.receivedAt != nil }.count
        guard received > 0 else { return "Receipt requested" }
        guard status.recipients.count > 1 else { return "Read receipt received" }
        return "\(received.formatted()) of \(status.recipients.count.formatted()) receipts received"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Read receipts").font(.headline)
                Text(Self.summary(for: status)).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    ForEach(status.recipients) { recipient in
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text(recipient.address).font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let date = recipient.receivedAt {
                                Label {
                                    Text("Receipt received \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .foregroundStyle(.secondary)
                                } icon: {
                                    Image(systemName: "checkmark.circle").foregroundStyle(Tokens.Status.success)
                                }
                                .font(.caption)
                            } else {
                                Text("No receipt yet").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Tokens.Popover.maxListHeight)
            Divider()
            Text("Receipts depend on the recipient's email app and settings. No receipt means the outcome is unknown. Dates show when receipts arrived.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.s4)
        .frame(width: Tokens.Popover.width)
        .frame(maxHeight: Tokens.Analytics.popoverMaxHeight)
    }
}
