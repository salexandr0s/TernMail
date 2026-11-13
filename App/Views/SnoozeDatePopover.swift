import SwiftUI

/// The bounds of the row that Choose Date & Time will snooze first.
struct SnoozeDateAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The list's one snooze date popover. It points at the row it was given, or
/// at the list when that row is out of view. A popover on every row made a
/// long scroll stall for more than 100 ms at a time.
struct SnoozeDatePopover: View {
    @Bindable var mailbox: MailboxModel
    let row: Anchor<CGRect>?

    var body: some View {
        GeometryReader { proxy in
            Color.clear.popover(
                isPresented: $mailbox.snoozeDateTargets.isPresent(),
                attachmentAnchor: .rect(.rect(row.map { proxy[$0] } ?? proxy.frame(in: .local))),
                arrowEdge: .trailing
            ) {
                if let ids = mailbox.snoozeDateTargets {
                    SnoozeDateSheet(
                        initial: SnoozeSchedule().wakeTime(for: .tomorrow, now: .now) ?? .now.addingTimeInterval(3600),
                        now: .now,
                        onSnooze: { mailbox.snooze(ids, until: $0) },
                        onCancel: { mailbox.snoozeDateTargets = nil }
                    )
                }
            }
            // Each request gets a new popover. One that was closed and asked
            // for again in the same moment would otherwise stay closed.
            .id(mailbox.snoozeDateRequest)
        }
        .allowsHitTesting(false)
    }
}
