import Observation
import SwiftUI

struct AssistantConversationView<Welcome: View>: View {
    let model: AssistantModel
    let scrollRequest: UUID
    let onOpenSource: (AssistantSource) -> Void
    let onOpenDraft: (String) -> Void
    @ViewBuilder let welcome: () -> Welcome
    @Environment(\.openWindow) private var openWindow
    @State private var scrollTracking = AssistantScrollTracking()

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                observedScroll(proxy, viewportHeight: viewport.size.height)
                    .overlay(alignment: .bottom) { jumpToLatest(proxy) }
            }
        }
        .background(Tokens.Surface.primary)
    }

    private func observedScroll(_ proxy: ScrollViewProxy, viewportHeight: CGFloat) -> some View {
        conversationScroll(viewportHeight: viewportHeight)
            .onChange(of: scrollRequest) { scrollTracking.followLatest(); scrollToLatest(proxy) }
            .onChange(of: scrollContent) { scrollToLatest(proxy) }
            .onAppear { scrollToLatest(proxy) }
    }

    private var scrollContent: AssistantScrollContent {
        let last = model.messages.last
        return AssistantScrollContent(messageCount: model.messages.count, text: last?.text,
                                      emailCount: last?.emailResults.count, draftCount: last?.draftIDs.count,
                                      taskCount: last?.taskResults.count, eventCount: last?.eventResults.count,
                                      proposalCount: last?.calendarProposals.count,
                                      availabilityCount: last?.availabilityChoices.count,
                                      state: last?.state, status: model.statusText)
    }

    private func conversationScroll(viewportHeight: CGFloat) -> some View {
        ScrollView {
            transcript
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.top, Tokens.Space.s2)
                .padding(.bottom, Tokens.Space.s5)
                .frame(maxWidth: Tokens.Assistant.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { content in
                        Color.clear.preference(key: AssistantScrollFrameKey.self,
                                               value: content.frame(in: .named("assistant-scroll")))
                    }
                }
        }
        .coordinateSpace(.named("assistant-scroll"))
        .onPreferenceChange(AssistantScrollFrameKey.self) { frame in
            scrollTracking.update(frame: frame, viewportHeight: viewportHeight)
        }
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if model.messages.isEmpty { welcome().id("assistant-welcome") }
            ForEach(model.messages.enumerated(), id: \.element.id) { index, message in
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    messageRow(message, at: index)
                }
            }
            if let error = model.errorMessage, error != model.messages.last?.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).padding(Tokens.Space.s3).ternSurface()
            }
            Color.clear.frame(height: Tokens.Space.s1).id("assistant-bottom")
        }
    }

    @ViewBuilder private func messageRow(_ message: AssistantMessage, at index: Int) -> some View {
        if beginsDay(at: index) { daySeparator(message.createdAt) }
        AssistantMessageView(message: message, startsGroup: startsGroup(at: index),
                             status: model.statusText, canRetry: model.canRetry(message.id),
                             onRetry: { scrollTracking.followLatest(); model.retry(message.id) },
                             onOpenSource: onOpenSource, onOpenSourceInNewWindow: openInNewWindow,
                             onOpenDraft: onOpenDraft, model: model)
        if !message.calendarProposals.isEmpty || !message.availabilityChoices.isEmpty {
            AssistantCalendarActionsView(message: message, model: model)
        }
    }

    private func openInNewWindow(_ source: AssistantSource) {
        model.openSourceInNewWindow(source) { openWindow(id: ConversationWindow.sceneID, value: $0) }
    }

    private func daySeparator(_ date: Date) -> some View {
        Text(dayTitle(date))
            .font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, Tokens.Space.s6)
            .padding(.bottom, Tokens.Space.s1)
    }

    @ViewBuilder private func jumpToLatest(_ proxy: ScrollViewProxy) -> some View {
        if !model.messages.isEmpty, !scrollTracking.followsLatest {
            Button("Jump to Latest", systemImage: "arrow.down") {
                scrollTracking.followLatest()
                proxy.scrollTo("assistant-bottom", anchor: .bottom)
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
            .background(Tokens.Surface.primary, in: Capsule())
            .padding(Tokens.Space.s3)
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard model.messages.isEmpty || scrollTracking.followsLatest else { return }
        Task { @MainActor in
            await Task.yield()
            if model.messages.isEmpty {
                scrollTracking.followLatest()
                proxy.scrollTo("assistant-welcome", anchor: .top)
                return
            }
            guard scrollTracking.followsLatest else { return }
            proxy.scrollTo("assistant-bottom", anchor: .bottom)
        }
    }

    private func startsGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = model.messages[index - 1], current = model.messages[index]
        return previous.isUser != current.isUser || current.createdAt.timeIntervalSince(previous.createdAt) > 300
    }

    private func beginsDay(at index: Int) -> Bool {
        index > 0 && !Calendar.current.isDate(model.messages[index - 1].createdAt, inSameDayAs: model.messages[index].createdAt)
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Separate layout growth from cumulative reader movement. Small trackpad steps
/// must add up even when a streamed text update arrives between them.
@MainActor @Observable
final class AssistantScrollTracking {
    private(set) var followsLatest = true
    @ObservationIgnored private var previousFrame: CGRect?
    @ObservationIgnored private var previousViewportHeight: CGFloat?
    @ObservationIgnored private var upwardDistance: CGFloat = 0

    func update(frame: CGRect, viewportHeight: CGFloat) {
        guard frame.height > 0, viewportHeight > 0 else { return }
        defer {
            previousFrame = frame
            previousViewportHeight = viewportHeight
        }
        if let previousFrame,
           previousFrame.size == frame.size, previousViewportHeight == viewportHeight {
            let movement = frame.minY - previousFrame.minY
            if movement > 0 { upwardDistance += movement }
            else if movement < 0 { upwardDistance = 0 }
        }
        let distanceFromBottom = frame.maxY - viewportHeight
        // Pause on the first upward step off the bottom; waiting for a larger
        // gesture would let the next streamed token undo a slow reader scroll.
        if upwardDistance > 0, distanceFromBottom > 0 {
            if followsLatest { followsLatest = false }
        } else if distanceFromBottom <= Tokens.Border.hairline {
            if !followsLatest { followsLatest = true }
        }
    }

    func followLatest() {
        if !followsLatest { followsLatest = true }
        upwardDistance = 0
        previousFrame = nil
        previousViewportHeight = nil
    }
}

/// One observation coalesces text and tool-result growth before scrolling.
private struct AssistantScrollContent: Equatable {
    let messageCount: Int
    let text: String?
    let emailCount: Int?
    let draftCount: Int?
    let taskCount: Int?
    let eventCount: Int?
    let proposalCount: Int?
    let availabilityCount: Int?
    let state: AssistantMessage.State?
    let status: String?
}

private struct AssistantScrollFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
