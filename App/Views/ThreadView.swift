import Accessibility
import MailStore
import MessageContent
import SwiftUI
import WebKit

struct ThreadView: View {
    let key: ThreadKey
    let mailbox: MailboxModel
    var selectedMessageID: String? = nil
    var isReaderActive = true
    /// A conversation window titles itself from this.
    var onDetailChange: ((ThreadDetail) -> Void)? = nil

    @State private var detail: ThreadDetail?
    @State private var expanded: Set<String> = []
    @State private var initializedExpansion = false
    @State private var blocker: WKContentRuleList?
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var bodyLoadFailed = false
    @State private var loadAttempt = 0
    @State private var calendarSuggestions = EmailCalendarModel()
    @State private var responseReview: EmailCalendarResponseReview?
    @State private var calendarNotice: String?
    @State private var calendarReplyBusy = false
    @State private var cancellationReview: EmailCalendarItem?
    @State private var resourceRevision = 0
    @State private var delayedRead = DelayedReadController()
    @State private var selectedMailQuote: SelectedMailQuote?
    @State private var focusedMessageID: String?
    @State private var hoveredLink: (messageID: String, url: String)?
    @State private var scrollPosition = ScrollPosition()
    @State private var paging = ReaderPaging()
    @State private var finder = ReaderFindModel()
    @FocusState private var readerFocused: Bool
    @AppStorage(ReadingPreferences.orderKey) private var messageOrder = ReadingPreferences.Order.oldestFirst.rawValue
    @AppStorage(ReadingPreferences.markReadKey) private var markReadPolicy = ReadingPreferences.MarkRead.immediately.rawValue
    @AppStorage(ReadingPreferences.readDelayKey) private var readDelay = 3.0
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct LoadIdentity: Equatable {
        let key: ThreadKey
        let attempt: Int
        let messageID: String?
    }

    private struct CalendarInterpretationIdentity: Equatable {
        let revision: String
        let access: Int
        let storeReady: Bool
    }

    private struct CalendarSuggestionLoadIdentity: Equatable {
        let detail: ThreadDetail?
        let storeReady: Bool
        let access: Int
        let timeZone: String
    }

    private struct ReadIdentity: Equatable {
        let key: ThreadKey
        let policy: String
        let delay: Double
        let isVisible: Bool
        let hasDetail: Bool
        let messageID: String?
    }

    private var readingDetail: ThreadDetail? {
        guard var detail else { return nil }
        if let selectedMessageID {
            detail.messages.removeAll { $0.id != selectedMessageID }
            guard !detail.messages.isEmpty else { return nil }
        }
        return detail
    }

    /// What the View and File menus can do with the open conversation.
    private var readerActions: ReaderActions? {
        guard let detail = readingDetail else { return nil }
        let ids = Set(detail.messages.map(\.id))
        return ReaderActions(
            canExpand: !ids.isSubset(of: expanded),
            canCollapse: !expanded.isDisjoint(with: ids),
            canPrint: !detail.messages.contains { $0.body == nil },
            expandAll: { expanded.formUnion(ids) },
            collapseAll: { expanded.subtract(ids) },
            print: { asPDF in
                ConversationPrintController.show(subject: detail.thread.subject, messages: detail.messages, exportsPDF: asPDF) { error in
                    if let error { mailbox.notice = .init(message: error, isError: true) }
                }
            },
            find: {
                // Collapsed messages have no body on screen, so Find opens them all.
                expanded.formUnion(ids)
                finder.show()
            }
        )
    }

    var body: some View {
        Group {
            if let detail = readingDetail {
                ScrollViewReader { scroll in
                    let messages = orderedMessages(detail)
                    ScrollView {
                        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                            ThreadHeading(detail: detail, key: key, mailbox: mailbox, messageID: selectedMessageID)
                            EmailCalendarSuggestionsView(model: calendarSuggestions, calendar: app.calendar.calendar, accountID: key.accountID,
                                onReview: { item in
                                    if item.kind == .cancelled { cancellationReview = item }
                                    else { Task { await app.calendar.reviewEmailSuggestion(item, key: key) } }
                                },
                                onOpenExisting: { item in
                                    guard let calendarID = item.existingCalendarID, let eventID = item.existingEventID else { return }
                                    Task { await app.calendar.openEvent(accountID: key.accountID, calendarID: calendarID, eventID: eventID) }
                                }, onRespond: { item, answer in
                                    guard !calendarReplyBusy else { return }
                                    calendarReplyBusy = true
                                    Task {
                                        defer { calendarReplyBusy = false }
                                        do { responseReview = try await app.calendar.prepareEmailResponse(item, answer: answer, key: key) }
                                        catch { calendarNotice = error.localizedDescription }
                                    }
                                }, onDismiss: { id in Task { await app.calendar.dismissEmailSuggestion(id, key: key) } })
                                .disabled(calendarReplyBusy)
                            if let calendarNotice {
                                Text(calendarNotice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if selectedMessageID == nil {
                            ThreadSummaryView(key: key, detail: detail, assistant: app.assistant,
                                isActive: isReaderActive) { source in
                                guard source.accountID == key.accountID, source.threadID == key.threadID,
                                      let messageID = source.messageID,
                                      detail.messages.contains(where: { $0.id == messageID }) else {
                                    app.openAssistantSource(source)
                                    return
                                }
                                expanded.insert(messageID)
                                Task { @MainActor in
                                    // Let the newly expanded message enter layout before scrolling.
                                    await Task.yield()
                                    withAnimation(reduceMotion ? nil : Tokens.Motion.standard()) {
                                        scroll.scrollTo(messageID, anchor: .top)
                                    }
                                }
                            }
                            }
                            VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                                ForEach(messages) { message in
                                    MessageView(
                                        message: message,
                                        blocker: blocker,
                                        isExpanded: expanded.contains(message.id),
                                        isFocused: readerFocused && focusedMessageID == message.id,
                                        resourceRevision: resourceRevision,
                                        bodyLoadFailed: bodyLoadFailed,
                                        mailbox: mailbox,
                                        finder: finder,
                                        compose: compose,
                                        onRetry: { loadAttempt += 1 },
                                        reportSelection: { text in
                                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                if selectedMailQuote?.belongsTo(accountID: message.record.accountID,
                                                    threadID: message.record.threadID, messageID: message.id) == true { selectedMailQuote = nil }
                                            } else {
                                                selectedMailQuote = SelectedMailQuote(accountID: message.record.accountID,
                                                    threadID: message.record.threadID, messageID: message.id, text: text)
                                            }
                                        },
                                        onHoverLink: { url in
                                            if let url { hoveredLink = (message.id, url) }
                                            else if hoveredLink?.messageID == message.id { hoveredLink = nil }
                                        },
                                        onMarkUnreadFromHere: {
                                            // This message and every later one, whichever way the list reads.
                                            mailbox.markUnread(messageIDs: detail.messages.drop { $0.id != message.id }.map(\.id),
                                                               accountID: key.accountID)
                                        }
                                    ) {
                                        if expanded.contains(message.id) {
                                            expanded.remove(message.id)
                                        } else {
                                            expanded.insert(message.id)
                                        }
                                    }
                                    .id(message.record.accountID + ":" + message.id)
                                    .id(message.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Tokens.Space.s4)
                    }
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: ReaderPage.self, of: ReaderPage.init) { _, page in paging.page = page }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($readerFocused)
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        moveFocus(by: press.key == .downArrow ? 1 : -1, in: messages, scroll: scroll)
                        return .handled
                    }
                    .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                        guard let id = focusedMessageID, messages.contains(where: { $0.id == id }) else { return .ignored }
                        if press.key == .rightArrow { expanded.insert(id) } else { expanded.remove(id) }
                        return .handled
                    }
                    .onKeyPress(.space) { pageDown() }
                    .overlay(alignment: .bottomLeading) { linkReadout }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if finder.isVisible { ReaderFindBar(model: finder) }
                    }
                    .onChange(of: messages.map(\.id), initial: true) { _, ids in finder.order = ids }
                    .onChange(of: app.mailURLs.focusRequest?.id, initial: true) { _, _ in
                        guard let request = app.mailURLs.focusRequest, request.key == key,
                              detail.messages.contains(where: { $0.id == request.messageID }) else { return }
                        expanded.insert(request.messageID)
                        Task { @MainActor in
                            await Task.yield()
                            withAnimation(reduceMotion ? nil : Tokens.Motion.standard()) {
                                scroll.scrollTo(request.messageID, anchor: .top)
                            }
                        }
                    }
                }
            } else if loadFailed {
                VStack(spacing: Tokens.Space.s4) {
                    TernEmptyState(
                        title: "Couldn't open this conversation",
                        systemImage: "exclamationmark.bubble",
                        message: "Try again, or select another conversation.",
                        fillsSpace: false
                    )
                    Button("Try Again") { loadAttempt += 1 }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasLoaded, readingDetail == nil {
                TernEmptyState(
                    title: "Conversation unavailable",
                    systemImage: "envelope.badge",
                    message: "No longer available in this mailbox. Select another conversation."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Opening conversation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Tokens.Surface.canvas)
        .focusedSceneValue(\.selectedMailQuote, isReaderActive ? selectedMailQuote : nil)
        .focusedSceneValue(\.readerActions, isReaderActive ? readerActions : nil)
        .userActivity(MailUserActivity.conversationType, isActive: isReaderActive && readingDetail != nil) { activity in
            MailUserActivity.describeConversation(
                activity, link: MailLink(accountID: key.accountID, threadID: key.threadID),
                subject: readingDetail?.thread.subject ?? "", email: mailbox.account(id: key.accountID)?.account.email
            )
        }
        .onChange(of: key) { _, _ in
            selectedMailQuote = nil
            finder.hide()
        }
        .onChange(of: detail, initial: true) { _, detail in if let detail { onDetailChange?(detail) } }
        .onChange(of: selectedMessageID) { _, _ in selectedMailQuote = nil }
        .task {
            blocker = await RemoteContentBlocker.ruleList()
        }
        .task(id: LoadIdentity(key: key, attempt: loadAttempt, messageID: selectedMessageID)) {
            loadFailed = false
            bodyLoadFailed = false
            hasLoaded = false
            if let selectedMessageID { expanded.insert(selectedMessageID) }
            var loading: Task<Void, Never>?
            defer { loading?.cancel() }
            do {
                for try await detail in mailbox.threadDetail(key) {
                    guard !Task.isCancelled else { return }
                    if !initializedExpansion, let last = detail?.messages.last {
                        // Older messages start collapsed; unread ones stay open.
                        expanded = Set(detail?.messages.filter(\.isUnread).map(\.id) ?? []).union([last.id])
                        initializedExpansion = true
                    }
                    self.detail = detail
                    hasLoaded = true
                    // Detail is published only after unread expansion is captured.
                    if loading == nil, detail != nil {
                        loading = Task {
                            // Hydration is independent of visibility. ReadIdentity owns
                            // automatic read changes after unread expansion is captured.
                            let opened = await mailbox.open(key, markRead: false)
                            guard !Task.isCancelled else { return }
                            bodyLoadFailed = !opened
                            if opened, let owner = mailbox.account(id: key.accountID) {
                                do {
                                    try await owner.engine.refreshCalendarInvitations(threadID: key.threadID)
                                    resourceRevision += 1
                                    if let current = readingDetail { await app.calendar.loadEmailSuggestions(calendarSuggestions, detail: current, key: key) }
                                } catch is CancellationError { return }
                                catch { calendarNotice = "Calendar invitations could not refresh. Showing cached suggestions." }
                            }
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.detail = nil
                loadFailed = true
            }
        }
        .task(id: ReadIdentity(key: key, policy: markReadPolicy, delay: readDelay, isVisible: isReaderActive,
            hasDetail: readingDetail != nil, messageID: selectedMessageID)) {
            delayedRead.cancel()
            guard isReaderActive, readingDetail != nil else { return }
            if markReadPolicy == ReadingPreferences.MarkRead.immediately.rawValue {
                await mailbox.markConversationRead(key, messageID: selectedMessageID)
            } else if markReadPolicy == ReadingPreferences.MarkRead.delayed.rawValue {
                delayedRead.schedule(delay: ReadingPreferences.readDelay(readDelay)) { await mailbox.markConversationRead(key, messageID: selectedMessageID) }
            }
        }
        .onDisappear {
            delayedRead.cancel()
            finder.hide()
        }
        .task(id: CalendarSuggestionLoadIdentity(detail: readingDetail, storeReady: app.calendar.store != nil,
            access: app.calendar.accessRevision, timeZone: app.calendar.calendar.timeZone.identifier)) {
            guard let detail = readingDetail else { return }
            await app.calendar.observeEmailSuggestions(calendarSuggestions, detail: detail, key: key)
        }
        .task(id: CalendarInterpretationIdentity(revision: calendarSuggestions.revision,
            access: app.assistant.calendarExtractionRevision, storeReady: app.calendar.store != nil)) {
            guard !calendarSuggestions.messages.isEmpty, app.calendar.store != nil else { return }
            guard let service = try? app.assistant.calendarExtractionService(for: key) else {
                calendarSuggestions.clearAIResults()
                return
            }
            await app.calendar.interpretEmailSuggestions(calendarSuggestions, key: key, service: service)
        }
        .confirmationDialog("Send invitation response?", isPresented: Binding(
            get: { responseReview != nil }, set: { if !$0 { responseReview = nil } }), presenting: responseReview) { review in
            Button("Send Response") {
                calendarReplyBusy = true
                Task {
                    defer { calendarReplyBusy = false }
                    do {
                        try await app.calendar.sendEmailResponse(review, key: key)
                        calendarNotice = "Your invitation response is queued."
                        AccessibilityNotification.Announcement("Your invitation response is queued.").post()
                    } catch { calendarNotice = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { review in Text(review.explanation) }
        .alert("Remove cancelled event?", isPresented: Binding(
            get: { cancellationReview != nil }, set: { if !$0 { cancellationReview = nil } }), presenting: cancellationReview) { item in
            Button("Remove Event", role: .destructive) {
                calendarReplyBusy = true
                Task {
                    defer { calendarReplyBusy = false }
                    do {
                        let display = try await app.calendar.emailCancellationEvent(item, key: key)
                        try await app.calendar.delete(display, scope: display.event.recurringEventId == nil ? .series : .occurrence)
                        calendarNotice = "The cancelled event was queued for removal."
                    } catch { calendarNotice = error.localizedDescription }
                }
            }
            Button("Keep Event", role: .cancel) {}
        } message: { item in
            Text("This email cancels “\(item.title)”. Remove the matching event from Google Calendar? Google may notify its attendees.")
        }
    }

    /// Opens a compose window once its draft exists. A failure shows as a notice.
    private func compose(_ start: MailboxModel.ComposeStart) {
        Task {
            guard let id = await mailbox.startCompose(start) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }

    private func orderedMessages(_ detail: ThreadDetail) -> [MessageDetail] {
        messageOrder == ReadingPreferences.Order.newestFirst.rawValue ? detail.messages.reversed() : detail.messages
    }

    /// ⌘↓ and ⌘↑ step through the messages as shown, opening each one. With
    /// nothing focused yet they start from the first open message.
    private func moveFocus(by delta: Int, in messages: [MessageDetail], scroll: ScrollViewProxy) {
        guard !messages.isEmpty else { return }
        let current = messages.firstIndex { $0.id == focusedMessageID }
            ?? messages.firstIndex { expanded.contains($0.id) }
            ?? (delta > 0 ? -1 : messages.count)
        let message = messages[min(max(current + delta, 0), messages.count - 1)]
        focusedMessageID = message.id
        expanded.insert(message.id)
        Task { @MainActor in
            await Task.yield()
            withAnimation(reduceMotion ? nil : Tokens.Motion.standard()) {
                scroll.scrollTo(message.id, anchor: .top)
            }
        }
    }

    /// Space shows the next screen of the conversation, keeping a strip of
    /// the previous one in view. At the end the key passes on.
    private func pageDown() -> KeyPress.Result {
        let page = paging.page
        let bottom = page.contentHeight - page.visibleHeight
        guard page.visibleHeight > 0, page.offset < bottom - Tokens.Border.hairline else { return .ignored }
        withAnimation(reduceMotion ? nil : Tokens.Motion.standard()) {
            scrollPosition.scrollTo(y: min(page.offset + page.visibleHeight - Tokens.Space.s8, bottom))
        }
        return .handled
    }

    /// The hovered link's destination, over the bottom of the reader like Safari's status bar.
    @ViewBuilder private var linkReadout: some View {
        if let url = hoveredLink?.url {
            Text(url)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Tokens.Space.s2)
                .padding(.vertical, Tokens.Space.s1)
                .background(.bar, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline))
                .padding(Tokens.Space.s2)
                .allowsHitTesting(false)
                .accessibilityLabel("Link destination: \(url)")
        }
    }
}

/// Where the reader is scrolled, for Space paging.
private struct ReaderPage: Equatable {
    var offset: CGFloat = 0
    var visibleHeight: CGFloat = 0
    var contentHeight: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        visibleHeight = geometry.containerSize.height
        contentHeight = geometry.contentSize.height
    }
}

/// Holds the scroll geometry outside SwiftUI state, so scrolling doesn't
/// rebuild the conversation.
@MainActor
private final class ReaderPaging {
    var page = ReaderPage()
}

/// The subject, followed by a chip for the Inbox and each user label the
/// conversation is in. Removing the Inbox chip archives the conversation.
private struct ThreadHeading: View {
    let detail: ThreadDetail
    let key: ThreadKey
    let mailbox: MailboxModel
    var messageID: String? = nil

    var body: some View {
        FlowLayout(spacing: Tokens.Space.s2) {
            Text(detail.thread.subject.isEmpty ? "No Subject" : detail.thread.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(chips, id: \.id) { label in
                if label.id == SystemLabel.inbox {
                    LabelChip(name: "Inbox", symbol: "tray", tint: .accentColor, removeHelp: "Archive", showTitle: "Show Inbox",
                              onShow: { show(label.id) }) {
                        if let messageID { mailbox.performReadingAction(.archive, name: "Archive", messageID: messageID, accountID: key.accountID) }
                        else { mailbox.perform(.archive, on: [key]) }
                    }
                } else {
                    let icon = LabelAppearance.shared.icon(for: label)
                    LabelChip(
                        name: label.name, symbol: icon == "tag" ? "tag.fill" : icon,
                        tint: Color(gmailHex: label.backgroundColor) ?? .secondary, removeHelp: "Remove Label", showTitle: "Show Label",
                        onShow: { show(label.id) }
                    ) {
                        if let messageID { mailbox.removeReadingLabel(label.id, messageID: messageID, accountID: key.accountID) }
                        else { mailbox.removeLabel(label.id, from: key) }
                    }
                }
            }
            let canPrint = !detail.messages.contains { $0.body == nil }
            Menu {
                Button("Print Conversation…") { printConversation() }
                Button("Export Conversation as PDF…") { printConversation(pdf: true) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel("Conversation actions")
            .disabled(!canPrint)
            .help(canPrint ? "Print or export the conversation" : "Print after all message bodies have loaded")
        }
        .padding(.bottom, Tokens.Space.s0_5)
    }

    /// Show Label and Show Inbox take the main window to that mailbox.
    private func show(_ labelID: String) {
        mailbox.selectedMailbox = .account(key.accountID, labelID)
    }

    private func printConversation(pdf: Bool = false) {
        ConversationPrintController.show(subject: detail.thread.subject, messages: detail.messages, exportsPDF: pdf) { error in
            if let error { mailbox.notice = .init(message: error, isError: true) }
        }
    }

    /// The Inbox, then user labels by name.
    private var chips: [LabelRecord] {
        let applied = detail.messages.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
        let labels = mailbox.account(id: key.accountID)?.labels ?? []
        let inbox = labels.filter { $0.id == SystemLabel.inbox && applied.contains($0.id) }
        let user = labels
            .filter { !$0.isSystem && applied.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return inbox + user
    }

}

/// A label the conversation carries. Its context menu removes the label or
/// shows the mailbox.
private struct LabelChip: View {
    let name: String
    var symbol = "tag.fill"
    let tint: Color
    let removeHelp: String
    let showTitle: String
    let onShow: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(name)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(removeHelp)
            .accessibilityLabel("\(removeHelp): \(name)")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.leading, Tokens.Space.s2)
        .padding(.trailing, Tokens.Space.s0_5)
        .background(Tokens.Surface.primary, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline))
        .contextMenu {
            Button(removeHelp, action: onRemove)
            Button(showTitle, action: onShow)
        }
    }
}

/// Wraps labels and attachment cards at the available width. Each item can
/// shrink to one row's width, including when it is narrower than a normal card.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                let origin = CGPoint(x: x, y: y + (row.height - item.size.height) / 2)
                subviews[item.index].place(at: origin, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

private struct MessageView: View {
    let message: MessageDetail
    let blocker: WKContentRuleList?
    let isExpanded: Bool
    /// Keyboard navigation in the reader rests on this message.
    let isFocused: Bool
    let resourceRevision: Int
    let bodyLoadFailed: Bool
    let mailbox: MailboxModel
    let finder: ReaderFindModel
    let compose: (MailboxModel.ComposeStart) -> Void
    let onRetry: () -> Void
    let reportSelection: (String) -> Void
    let onHoverLink: (String?) -> Void
    let onMarkUnreadFromHere: () -> Void
    let onToggle: () -> Void

    @State private var rendered: RenderedMessage?
    @State private var hasNoText = false
    @State private var height: CGFloat = 0
    @State private var inlineResources = InlineResourceMap()
    @State private var allowsImagesOnce = false
    @State private var allowsSenderImages = false
    @State private var showsLightBackground = false
    @State private var selectedText = ""
    @State private var activeBlocker: WKContentRuleList?
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ReadingPreferences.blockImagesKey) private var blocksImages = true
    @AppStorage(ReadingPreferences.adaptDarkKey) private var adaptsDark = true
    @AppStorage(ReadingPreferences.textScaleKey) private var textScale = 1.0
    @AppStorage(ReadingPreferences.sizeKey) private var showsSize = false

    private struct RenderIdentity: Equatable {
        let accountID: String
        let messageID: String
        let body: MessageBodyRecord?
        let resourceRevision: Int
        let allowsImages: Bool
        let showsLight: Bool
        let adaptsDark: Bool
        let textScale: Double
        let isExpanded: Bool
    }

    private var allowsImages: Bool { allowsImagesOnce || allowsSenderImages || !blocksImages }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.vertical, Tokens.Space.s2)

            if isExpanded {
                Divider()
                    .padding(.horizontal, Tokens.Space.s3)
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    content
                    if !message.attachments.isEmpty {
                        ReceivedAttachmentsView(attachments: message.attachments, mailbox: mailbox)
                    }
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                    .strokeBorder(Color.accentColor, lineWidth: Tokens.Border.focus)
                    .allowsHitTesting(false)
            }
        }
        .ternAnimation(value: isExpanded)
        .task(id: RenderIdentity(accountID: message.record.accountID, messageID: message.id, body: message.body,
            resourceRevision: resourceRevision, allowsImages: allowsImages, showsLight: showsLightBackground, adaptsDark: adaptsDark,
            textScale: textScale, isExpanded: isExpanded)) {
            await render()
        }
        .task(id: message.record.sender) {
            let allowed = try? await mailbox.accountStore?.allowedImageSenders(accountID: message.record.accountID)
            guard !Task.isCancelled else { return }
            allowsSenderImages = allowed?.contains(senderAddress.lowercased()) == true
        }
        .onChange(of: isExpanded) { _, expanded in if !expanded { selectedText = ""; onHoverLink(nil) } }
        .onChange(of: selectedText) { _, text in reportSelection(text) }
        .onDisappear { reportSelection(""); onHoverLink(nil) }
        .onChange(of: allowsImages) { _, _ in rendered = nil; selectedText = ""; onHoverLink(nil) }
        .onReceive(NotificationCenter.default.publisher(for: ReadingPreferences.imagePermissionChanged)) { change in
            guard change.userInfo?["account"] as? String == message.record.accountID,
                  change.userInfo?["sender"] as? String == senderAddress.lowercased(),
                  let allowed = change.userInfo?["allowed"] as? Bool else { return }
            allowsSenderImages = allowed
            if !allowed { allowsImagesOnce = false }
        }
    }

    /// A collapsed header opens on a click anywhere; its controls keep their own clicks.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                senderHeader
                    .frame(minWidth: Tokens.Layout.senderMinWidth)
                messageMetadata
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                senderHeader
                HStack {
                    Spacer(minLength: 0)
                    messageMetadata
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isExpanded { onToggle() } }
        .contextMenu {
            MessageMenuItems(message: message, mailbox: mailbox, selectedText: selectedText,
                             markUnreadFromHere: onMarkUnreadFromHere, showsStar: true)
        }
    }

    private var senderHeader: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Button(action: onToggle) {
                ContactAvatar(accountID: message.record.accountID, address: senderAddress, name: senderName,
                    cache: mailbox.cache, accounts: mailbox.accountStore)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse message" : "Expand message")
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                HStack(spacing: Tokens.Space.s1) {
                    MessageAddressMenu(address: .init(name: senderName, address: senderAddress), accountID: message.record.accountID, mailbox: mailbox)
                        .font(.body.weight(.semibold))
                    Button(action: onToggle) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse message" : "Expand message")
                }
                if isExpanded {
                    recipients("To:", message.record.recipients)
                    if let cc = message.record.cc, !cc.isEmpty {
                        recipients("Cc:", cc)
                    }
                } else {
                    Text(message.record.snippet)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Tokens.Space.s2)
        }
        .help(message.record.sender)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var messageMetadata: some View {
        VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
            Text(ThreadDate.short(message.record.date))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(Self.dateFormatter.string(from: message.record.date))
            if isExpanded {
                MessageActions(message: message, mailbox: mailbox, selectedText: selectedText, compose: compose)
                if showsSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(message.record.sizeEstimate), countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if message.isStarred {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(Tokens.Status.star)
                    .accessibilityLabel("Starred")
            }
        }
        .fixedSize()
    }

    private func recipients(_ title: String, _ header: String) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            Text(title).foregroundStyle(.secondary)
            ForEach(Array(EmailAddress.parseList(header).enumerated()), id: \.offset) { _, address in
                MessageAddressMenu(address: address, accountID: message.record.accountID, mailbox: mailbox)
            }
        }
            .font(.subheadline)
            .lineLimit(1)
            .help(header)
    }

    /// "Today at 10:35", "Yesterday at 18:02", or the date and time.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    @ViewBuilder
    private var content: some View {
        if let rendered {
            if rendered.blockedRemoteContent > 0 {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Label("Remote content blocked for privacy", systemImage: "eye.slash")
                    if !allowsImages {
                        HStack {
                            Button("Load Images") { allowsImagesOnce = true }
                            Button("Always Load for Sender") { allowSenderImages() }
                        }.buttonStyle(.borderless)
                    }
                }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(Tokens.Space.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            if rendered.blockedTrackers > 0 {
                Label("\(rendered.blockedTrackers) tracking \(rendered.blockedTrackers == 1 ? "image" : "images") blocked", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if allowsSenderImages {
                Button("Block Images for Sender") { allowSenderImages(false) }
                    .font(.callout).buttonStyle(.borderless)
            }
            // Light mail already reads as the sender made it; the switch matters in Dark.
            if adaptsDark, colorScheme == .dark {
                Button(showsLightBackground ? "Use Dark Mode" : "Show with Light Background") { showsLightBackground.toggle() }
                    .font(.callout).buttonStyle(.borderless)
            }
            MessageWebView(html: rendered.html, blocker: activeBlocker ?? blocker, height: $height, resources: inlineResources,
                adaptsDarkMode: adaptsDark && !showsLightBackground && !rendered.hasAuthoredDarkStyles,
                forcesLightAppearance: showsLightBackground,
                onHover: onHoverLink, onSelectionChange: { selectedText = $0 },
                onOpenMailLink: { app.mailURLs.receive($0) },
                onCreate: { finder.register($0, for: message.id) }, onDismantle: { finder.unregister($0) })
                .id(inlineResources.scope + ":\(showsLightBackground):\(adaptsDark)")
                .frame(height: max(height, Tokens.Space.s5))
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .accessibilityLabel("Message from \(senderName)")
        } else if hasNoText {
            Text("This message has no text.")
                .foregroundStyle(.secondary)
        } else if message.body == nil, bodyLoadFailed {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Label("Couldn't load this message", systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.secondary)
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
            }
        } else {
            ProgressView("Loading message…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var senderName: String {
        let sender = message.record.sender
        guard let open = sender.firstIndex(of: "<") else { return sender }
        let name = sender[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        return name.isEmpty ? sender : name
    }

    private var senderAddress: String {
        EmailAddress.parseList(message.record.sender).first?.address ?? message.record.sender
    }

    private func allowSenderImages(_ allowed: Bool = true) {
        Task {
            do {
                guard let store = mailbox.accountStore else {
                    mailbox.notice = .init(message: "This sender's image preference could not be saved.", isError: true)
                    return
                }
                try await store.setImageSenderAllowed(allowed, address: senderAddress, accountID: message.record.accountID)
                NotificationCenter.default.post(name: ReadingPreferences.imagePermissionChanged, object: nil,
                    userInfo: ["account": message.record.accountID, "sender": senderAddress.lowercased(), "allowed": allowed])
            } catch { mailbox.notice = .init(message: "This sender's image preference could not be saved.", isError: true) }
        }
    }

    /// Sanitizing can take a moment on large mail, so it runs off the main actor.
    /// Without the rule list that blocks remote loads, only text is shown.
    private func render() async {
        guard isExpanded else {
            rendered = nil; selectedText = ""; onHoverLink(nil); height = 0
            inlineResources = InlineResourceMap()
            return
        }
        guard let body = message.body else {
            rendered = nil
            hasNoText = false
            height = 0
            return
        }
        let extracted = ExtractedBody(html: body.html, plainText: body.plainText)
        let records = (try? await mailbox.cache.mimeResources(messageID: message.id, accountID: message.record.accountID)) ?? []
        guard !Task.isCancelled else { return }
        let resources = records.map { InlineMIMEResource(contentID: $0.contentID, partID: $0.partID, mimeType: $0.mimeType, data: $0.data) }
        if inlineResources.resources.values.sorted(by: { $0.contentID < $1.contentID }) != resources.sorted(by: { $0.contentID < $1.contentID }) {
            inlineResources = InlineResourceMap(resources: resources)
        }
        let rules = await RemoteContentBlocker.ruleList(allowsRemoteImages: allowsImages)
        guard !Task.isCancelled else { return }
        activeBlocker = rules
        let textOnly = rules == nil
        let policy = MessageRenderPolicy(allowsRemoteImages: allowsImages, inlineResources: inlineResources, textScale: textScale)
        let result = await Task.detached(priority: .userInitiated) {
            textOnly ? MessageDocument.renderText(extracted) : MessageDocument.render(extracted, policy: policy)
        }.value
        guard !Task.isCancelled else { return }
        rendered = result
        hasNoText = result == nil
    }
}
