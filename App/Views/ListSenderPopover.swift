import SwiftUI

/// Which row's sender details the list shows. Rows ask, and the list has the
/// one popover: a popover on every row made a long scroll stall for more than
/// 100 ms at a time.
@MainActor @Observable final class ListSenderPopoverState {
    struct Request: Equatable {
        let row: MailListRowID
        let address: String
        let name: String
        let logoLookup: LogoLookup
        /// Tells one request from the next for the same row.
        fileprivate let serial: Int
    }

    private(set) var request: Request?
    private var serial = 0

    func show(row: MailListRowID, address: String, name: String, logoLookup: LogoLookup) {
        serial += 1
        request = Request(row: row, address: address, name: name, logoLookup: logoLookup, serial: serial)
    }

    /// Closes `request`, or whatever is open when it is nil. A popover that
    /// reports its closing late leaves a newer request alone.
    func close(_ request: Request? = nil) {
        if request == nil || request == self.request { self.request = nil }
    }
}

/// The bounds of the avatar the list's sender popover points at.
private struct ListSenderAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Goes behind a row's avatar and marks it while the popover is open for that
/// row. Only this view reads the request, so opening the popover draws no row
/// again.
struct ListSenderAnchor: View {
    let row: MailListRowID
    @Environment(ListSenderPopoverState.self) private var state: ListSenderPopoverState?

    var body: some View {
        if state?.request?.row == row {
            Color.clear.anchorPreference(key: ListSenderAnchorKey.self, value: .bounds) { $0 }
        }
    }
}

extension View {
    /// Gives the rows inside one sender popover to share.
    func listSenderPopover(mailbox: MailboxModel) -> some View {
        modifier(ListSenderPopoverHost(mailbox: mailbox))
    }
}

private struct ListSenderPopoverHost: ViewModifier {
    let mailbox: MailboxModel
    @State private var state = ListSenderPopoverState()

    func body(content: Content) -> some View {
        content
            .environment(state)
            .overlayPreferenceValue(ListSenderAnchorKey.self) {
                ListSenderPopover(state: state, mailbox: mailbox, avatar: $0)
            }
    }
}

private struct ListSenderPopover: View {
    let state: ListSenderPopoverState
    let mailbox: MailboxModel
    let avatar: Anchor<CGRect>?

    var body: some View {
        let request = state.request
        GeometryReader { proxy in
            Color.clear.popover(
                isPresented: Binding(get: { request != nil && avatar != nil },
                                     set: { if !$0 { state.close(request) } }),
                attachmentAnchor: .rect(.rect(avatar.map { proxy[$0] } ?? .zero)),
                arrowEdge: .trailing
            ) {
                if let request {
                    SenderProfilePopover(accountID: request.row.accountID, address: request.address,
                                         name: request.name, mailbox: mailbox)
                        .logoLookup(request.logoLookup)
                }
            }
            // Each request gets a new popover. One that was closed and asked
            // for again in the same moment would otherwise stay closed.
            .id(request?.serial)
        }
        .allowsHitTesting(false)
        // The row left the list's view or now shows another conversation.
        .onChange(of: avatar == nil) { _, gone in
            if gone { state.close() }
        }
    }
}
