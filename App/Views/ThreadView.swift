import Accessibility
import Diagnostics
import MailStore
import MessageContent
import SwiftUI
import WebKit

struct ThreadView: View {
    let key: ThreadKey
    let mailbox: MailboxModel
    var selectedMessageID: String? = nil
    var selectedAttachmentPartID: String? = nil
    var isReaderActive = true
    var retainsHiddenBody = false
    var retainsSourceSnapshot = true
    var interaction: ReaderInteraction? = nil
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
    @State private var calendarInterpretationAttempt = 0
    @State private var responseReview: EmailCalendarResponseReview?
    @State private var calendarNotice: String?
    @State private var calendarReplyBusy = false
    @State private var cancellationReview: EmailCalendarItem?
    @State private var lastVisibleMessageID: String?
    @State private var primaryBodyReady = false
    @State private var initiallyMissingBodies: Set<String> = []
    @State private var availabilityGeneration: UInt64?
    private struct BodyAvailability { let fetchedAt: Date; let instant: ContinuousClock.Instant }
    @State private var bodyAvailability: [String: BodyAvailability] = [:]
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
    @AppStorage(ReadingPreferences.adaptDarkKey) private var adaptsDark = true
    @AppStorage(ReadingPreferences.lightBackgroundSendersKey) private var lightBackgroundSenders = ""
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private struct LoadIdentity: Equatable {
        let key: ThreadKey
        let attempt: Int
        let messageID: String?
        let isActive: Bool
    }

    private struct CalendarInterpretationIdentity: Equatable {
        let revision: String
        let attempt: Int
        let access: Int
        let storeReady: Bool
        let isActive: Bool
    }

    private struct CalendarSuggestionLoadIdentity: Equatable {
        let detail: ThreadDetail?
        let storeReady: Bool
        let access: Int
        let timeZone: String
        let isActive: Bool
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

    /// View ▸ Show with Light Background turns the choice on or off for every
    /// sender in the conversation. It's offered while Dark Mode adapts mail.
    private var readerAppearance: ReaderAppearance? {
        guard adaptsDark, colorScheme == .dark, let detail = readingDetail else { return nil }
        let senders = Set(detail.messages.compactMap(\.parsedSenderAddress))
        guard !senders.isEmpty else { return nil }
        let isOn = senders.allSatisfy(LightBackgroundSenders(storage: lightBackgroundSenders).contains)
        return ReaderAppearance(showsLightBackground: isOn) {
            var stored = LightBackgroundSenders(storage: lightBackgroundSenders)
            for sender in senders { stored.set(!isOn, for: sender) }
            lightBackgroundSenders = stored.storage
        }
    }

    private func messageRow(_ message: MessageDetail, in detail: ThreadDetail, scroll: ScrollViewProxy) -> some View {
        MessageView(
            message: message,
            selectedAttachmentPartID: message.id == selectedMessageID ? selectedAttachmentPartID : nil,
            blocker: blocker,
            isExpanded: expanded.contains(message.id),
            isFocused: readerFocused && focusedMessageID == message.id,
            isReaderActive: isReaderActive,
            retainsHiddenBody: retainsHiddenBody && lastVisibleMessageID == message.id,
            bodyLoadFailed: bodyLoadFailed,
            requiredNetwork: availabilityGeneration == interaction?.body && initiallyMissingBodies.contains(message.id),
            bodyAvailableAt: bodyAvailability[message.id]?.instant,
            mailbox: mailbox,
            finder: finder,
            onVisible: { if isReaderActive { lastVisibleMessageID = message.id } },
            onReadable: { tier, readyAt in
                guard isReaderActive else { return }
                primaryBodyReady = true
                if let generation = interaction?.body {
                    if let readyAt {
                        NavigationPerformance.shared.requiredContentReady(.reader, generation: generation, at: readyAt)
                    }
                    NavigationPerformance.shared.contentReady(.reader, cacheTier: tier, generation: generation)
                }
            },
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
            focusedMessageID = message.id
            readerFocused = true
            if expanded.contains(message.id) {
                expanded.remove(message.id)
                Task { @MainActor in
                    await Task.yield()
                    guard !expanded.contains(message.id) else { return }
                    // Keep the collapsed header reachable when removing a tall body
                    // makes AppKit clamp the scroll position near the conversation's end.
                    scroll.scrollTo(message.id)
                }
            } else {
                expanded.insert(message.id)
            }
        }
        .id(message.id)
    }

    private var conversationContent: some View {
        Group {
            if let detail = readingDetail {
                ScrollViewReader { scroll in
                    let messages = orderedMessages(detail)
                    ScrollView {
                        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                            ThreadHeading(detail: detail, key: key, mailbox: mailbox,
                                          messageID: selectedMessageID, actions: readerActions)
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
                                }, onDismiss: { id in Task { await app.calendar.dismissEmailSuggestion(id, key: key) } },
                                onRetry: { calendarInterpretationAttempt += 1 },
                                tasks: app.tasks,
                                taskRequest: { item in
                                    EmailTaskRequest.calendarSuggestion(item, detail: detail, calendar: app.calendar.calendar,
                                        accountEmail: mailbox.account(id: key.accountID)?.account.email)
                                }, onAddTask: { request in
                                    app.showTasks()
                                    Task { await app.tasks.add(request) }
                                })
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
                            LazyVStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                                ForEach(messages) { message in
                                    messageRow(message, in: detail, scroll: scroll)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Tokens.Space.s4)
                        .background(PerformanceScrollSurfaceMarker(name: "reader", isActive: isReaderActive))
                    }
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: ReaderPage.self, of: ReaderPage.init) { _, page in paging.page = page }
                    .focusable(isReaderActive)
                    .focusEffectDisabled()
                    .focused($readerFocused)
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        guard isReaderActive, press.modifiers.contains(.command) else { return .ignored }
                        moveFocus(by: press.key == .downArrow ? 1 : -1, in: messages, scroll: scroll)
                        return .handled
                    }
                    .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                        guard isReaderActive, let id = focusedMessageID, messages.contains(where: { $0.id == id }) else { return .ignored }
                        if press.key == .rightArrow { expanded.insert(id) } else { expanded.remove(id) }
                        return .handled
                    }
                    .onKeyPress(.space) { pageDown() }
                    .overlay(alignment: .bottomLeading) { linkReadout }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if finder.isVisible { ReaderFindBar(model: finder) }
                    }
                    .onChange(of: messages.map(\.id), initial: true) { _, ids in finder.order = ids }
                    .onChange(of: finder.requestRevision) { _, _ in
                        guard isReaderActive, let id = finder.requestedMessageID else { return }
                        expanded.insert(id)
                        scroll.scrollTo(id, anchor: .top)
                    }
                    .task(id: ReaderSearchIdentity(messages: messages, isEnabled: finder.isVisible && isReaderActive)) {
                        guard finder.isVisible, isReaderActive else { return }
                        await finder.prepareSearch(messages: messages)
                    }
                    .onChange(of: app.mailURLs.focusRequest?.id, initial: true) { _, _ in
                        guard isReaderActive, let request = app.mailURLs.focusRequest, request.key == key,
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
                        title: "Couldn't Open This Conversation",
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
                    title: "Conversation Unavailable",
                    systemImage: "envelope.badge",
                    message: "No longer available in this mailbox. Select another conversation."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Opening conversation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var body: some View {
        conversationContent
        .disabled(!isReaderActive)
        .background(Tokens.Surface.canvas)
        .background(VisibleContentProbe(kind: .reader, isActive: isReaderActive && primaryBodyReady && interaction?.body != nil,
            revision: Int(truncatingIfNeeded: interaction?.body ?? 0)))
        .background(VisibleContentProbe(kind: .readerHeader, isActive: isReaderActive && readingDetail != nil && interaction?.header != nil,
            revision: Int(truncatingIfNeeded: interaction?.header ?? 0)))
        .focusedSceneValue(\.selectedMailQuote, isReaderActive ? selectedMailQuote : nil)
        .focusedSceneValue(\.readerActions, isReaderActive ? readerActions : nil)
        .userActivity(MailUserActivity.conversationType, isActive: isReaderActive && readingDetail != nil) { activity in
            MailUserActivity.describeConversation(
                activity, link: MailLink(accountID: key.accountID, threadID: key.threadID),
                subject: readingDetail?.thread.subject ?? "", email: mailbox.account(id: key.accountID)?.account.email
            )
        }
        .focusedSceneValue(\.readerAppearance, isReaderActive ? readerAppearance : nil)
        .onChange(of: key) { _, _ in
            selectedMailQuote = nil
            finder.hide()
        }
        .onChange(of: detail, initial: true) { _, detail in if let detail { onDetailChange?(detail) } }
        .onChange(of: selectedMessageID) { _, _ in selectedMailQuote = nil }
        .onChange(of: retainsSourceSnapshot) { _, retain in
            guard !retain, !isReaderActive else { return }
            detail = nil; hasLoaded = false; primaryBodyReady = false
            bodyAvailability.removeAll()
            finder.discardSourceText()
            calendarSuggestions = EmailCalendarModel()
        }
        .task {
            blocker = await RemoteContentBlocker.ruleList()
        }
        .task(id: LoadIdentity(key: key, attempt: loadAttempt, messageID: selectedMessageID, isActive: isReaderActive)) {
            guard isReaderActive else { return }
            loadFailed = false
            bodyLoadFailed = false
            if let selectedMessageID { expanded.insert(selectedMessageID) }
            var loading: Task<Void, Never>?
            var recordedAvailability = false
            defer { loading?.cancel() }
            do {
                for try await detail in mailbox.threadDetail(key) {
                    guard !Task.isCancelled else { return }
                    let deliveredAt = ContinuousClock.now
                    for message in detail?.messages ?? [] {
                        if let body = message.body, bodyAvailability[message.id]?.fetchedAt != body.fetchedAt {
                            bodyAvailability[message.id] = BodyAvailability(fetchedAt: body.fetchedAt, instant: deliveredAt)
                        }
                    }
                    if !recordedAvailability, let messages = detail?.messages, !messages.isEmpty {
                        initiallyMissingBodies = Set(messages.filter { $0.body == nil }.map(\.id))
                        availabilityGeneration = interaction?.body
                        recordedAvailability = true
                    }
                    if !initializedExpansion, let messages = detail?.messages, !messages.isEmpty {
                        expanded = ReadingPreferences.initiallyExpanded(ids: messages.map(\.id),
                            unread: Set(messages.filter(\.isUnread).map(\.id)), selected: selectedMessageID)
                        initializedExpansion = true
                    }
                    self.detail = detail
                    hasLoaded = true
                    if detail != nil, let generation = interaction?.header {
                        NavigationPerformance.shared.contentReady(.readerHeader, cacheTier: .local, generation: generation)
                    }
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
        .onChange(of: isReaderActive, initial: true) { _, active in
            if !active { delayedRead.cancel(); finder.hide(); selectedMailQuote = nil; hoveredLink = nil; readerFocused = false }
            else if readingDetail != nil, let generation = interaction?.header {
                NavigationPerformance.shared.contentReady(.readerHeader, cacheTier: .retained, generation: generation)
            }
        }
        .task(id: CalendarSuggestionLoadIdentity(detail: readingDetail, storeReady: app.calendar.store != nil,
            access: app.calendar.accessRevision, timeZone: app.calendar.calendar.timeZone.identifier,
            isActive: isReaderActive && primaryBodyReady)) {
            guard isReaderActive, primaryBodyReady, let detail = readingDetail else { return }
            await app.calendar.observeEmailSuggestions(calendarSuggestions, detail: detail, key: key)
        }
        .task(id: CalendarInterpretationIdentity(revision: calendarSuggestions.revision,
            attempt: calendarInterpretationAttempt,
            access: app.assistant.calendarExtractionRevision, storeReady: app.calendar.store != nil, isActive: isReaderActive && primaryBodyReady)) {
            guard isReaderActive, primaryBodyReady, !calendarSuggestions.messages.isEmpty, app.calendar.store != nil else { return }
            guard let service = try? app.assistant.calendarExtractionService(for: key) else {
                calendarSuggestions.clearAIResults()
                return
            }
            await app.calendar.interpretEmailSuggestions(calendarSuggestions, key: key, service: service)
        }
        .confirmationDialog("Send invitation response?", isPresented: $responseReview.isPresent(), presenting: responseReview) { review in
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
        .alert("Remove cancelled event?", isPresented: $cancellationReview.isPresent(), presenting: cancellationReview) { item in
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
        guard isReaderActive else { return .ignored }
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
                .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
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
/// conversation is in. The Inbox chip has no remove button because Archive
/// is in the toolbar; its context menu still archives.
private struct ThreadHeading: View {
    let detail: ThreadDetail
    let key: ThreadKey
    let mailbox: MailboxModel
    var messageID: String? = nil
    var actions: ReaderActions? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Text(detail.thread.subject.isEmpty ? "No Subject" : detail.thread.subject)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                let canPrint = !detail.messages.contains { $0.body == nil }
                Menu {
                    if let actions {
                        Button("Expand All Messages", action: actions.expandAll).disabled(!actions.canExpand)
                        Button("Collapse All Messages", action: actions.collapseAll).disabled(!actions.canCollapse)
                        Divider()
                    }
                    Button("Print Conversation…") { printConversation() }.disabled(!canPrint)
                    Button("Export Conversation as PDF…") { printConversation(pdf: true) }.disabled(!canPrint)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize()
                .ternHover()
                .accessibilityLabel("Conversation actions")
                .help("Conversation actions")
            }
            if !chips.isEmpty {
                FlowLayout(spacing: Tokens.Space.s1_5) {
                    labelChips
                }
            }
        }
        .padding(.bottom, Tokens.Space.s0_5)
    }

    private var labelChips: some View {
        ForEach(chips, id: \.id) { label in
            if label.id == SystemLabel.inbox {
                LabelChip(name: "Inbox", symbol: "tray", tint: .accentColor, removeHelp: "Archive", showTitle: "Show Inbox",
                          showsRemoveButton: false, onShow: { show(label.id) }) {
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
    var showsRemoveButton = true
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
            if showsRemoveButton {
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
        }
        .frame(minHeight: Tokens.Space.s5)
        .font(.caption.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.leading, Tokens.Space.s2)
        .padding(.trailing, showsRemoveButton ? Tokens.Space.s0_5 : Tokens.Space.s2)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .ternOutline(radius: Tokens.Radius.sm, style: .contrastOnly)
        .contextMenu {
            Button(removeHelp, action: onRemove)
            Button(showTitle, action: onShow)
        }
    }
}
