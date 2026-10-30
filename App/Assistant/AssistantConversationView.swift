import SwiftUI

struct AssistantConversationView<Welcome: View>: View {
    let model: AssistantModel
    let scrollRequest: UUID
    let onOpenSource: (AssistantSource) -> Void
    let onOpenDraft: (String) -> Void
    @ViewBuilder let welcome: () -> Welcome
    @State private var scrollTracking = AssistantScrollTracking()

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        if model.messages.isEmpty { welcome() }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            if beginsDay(at: index) {
                                Text(dayTitle(message.createdAt))
                                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s1)
                                    .background(Tokens.Surface.muted, in: Capsule())
                                    .frame(maxWidth: .infinity)
                            }
                            AssistantMessageView(message: message, startsGroup: startsGroup(at: index),
                                                 status: model.statusText, canRetry: model.canRetry(message.id),
                                                 onRetry: { scrollTracking.followLatest(); model.retry(message.id) },
                                                 onOpenSource: onOpenSource, onOpenDraft: onOpenDraft)
                            if !message.calendarProposals.isEmpty || !message.availabilityChoices.isEmpty {
                                AssistantCalendarActionsView(message: message, model: model)
                            }
                        }
                        if let error = model.errorMessage, error != model.messages.last?.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled).padding(Tokens.Space.s3).ternSurface()
                        }
                        Color.clear.frame(height: Tokens.Space.s1).id("assistant-bottom")
                    }
                    .padding(Tokens.Space.s3)
                    .frame(maxWidth: Tokens.Assistant.contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: AssistantScrollFrameKey.self,
                                                   value: content.frame(in: .named("assistant-scroll")))
                        }
                    }
                }
                .coordinateSpace(name: "assistant-scroll")
                .onPreferenceChange(AssistantScrollFrameKey.self) { frame in
                    scrollTracking.update(frame: frame, viewportHeight: viewport.size.height)
                }
                .onChange(of: scrollRequest) { scrollTracking.followLatest(); scrollToLatest(proxy) }
                .onChange(of: model.messages.count) { scrollToLatest(proxy) }
                .onChange(of: model.messages.last?.text) { scrollToLatest(proxy) }
                .onChange(of: model.messages.last?.emailResults.count) { scrollToLatest(proxy) }
                .onChange(of: model.messages.last?.state) { scrollToLatest(proxy) }
                .onChange(of: model.statusText) { scrollToLatest(proxy) }
                .onAppear { scrollToLatest(proxy) }
                .overlay(alignment: .bottom) {
                    if !scrollTracking.followsLatest {
                        Button("Jump to latest", systemImage: "arrow.down") {
                            scrollTracking.followLatest()
                            proxy.scrollTo("assistant-bottom", anchor: .bottom)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .background(Tokens.Surface.primary, in: Capsule())
                        .padding(Tokens.Space.s2)
                    }
                }
            }
        }
        .background(Tokens.Assistant.chatBackground)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard scrollTracking.followsLatest else { return }
        Task { @MainActor in
            await Task.yield()
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
        index == 0 || !Calendar.current.isDate(model.messages[index - 1].createdAt, inSameDayAs: model.messages[index].createdAt)
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Separate layout growth from cumulative reader movement. Small trackpad steps
/// must add up even when a streamed text update arrives between them.
struct AssistantScrollTracking {
    private(set) var followsLatest = true
    private var previousFrame: CGRect?
    private var previousViewportHeight: CGFloat?
    private var upwardDistance: CGFloat = 0

    mutating func update(frame: CGRect, viewportHeight: CGFloat) {
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
            followsLatest = false
        } else if distanceFromBottom <= Tokens.Border.hairline {
            followsLatest = true
        }
    }

    mutating func followLatest() {
        followsLatest = true
        upwardDistance = 0
        previousFrame = nil
        previousViewportHeight = nil
    }
}

private struct AssistantScrollFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
