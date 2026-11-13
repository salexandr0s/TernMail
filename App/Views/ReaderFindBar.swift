import AppKit
import MailStore
import SwiftUI
import WebKit

struct ReaderSearchIdentity: Equatable {
    struct Message: Equatable { let id: String; let body: ReaderBodyVersion? }
    let messages: [Message]
    let isEnabled: Bool
    init(messages: [MessageDetail], isEnabled: Bool) {
        self.messages = messages.map { Message(id: $0.id, body: $0.body.map(ReaderBodyVersion.init)) }
        self.isEnabled = isEnabled
    }
}

/// Edit ▸ Find… over the open conversation. Each message body is its own web
/// view, so a search steps through them in reading order and wraps around.
@MainActor @Observable
final class ReaderFindModel {
    var isVisible = false
    var query = ""
    /// The last search found nothing in any message.
    var cameUpEmpty = false
    /// Find… while the bar is already up puts the cursor back in the field.
    var focusRequest = 0
    /// Message IDs as shown, so Next and Previous follow the reading order.
    var order: [String] = []
    private(set) var requestedMessageID: String?
    private(set) var requestRevision = 0

    /// How long typing has to pause before the query is searched.
    private static let queryDelay: Duration = .milliseconds(120)
    /// How long a search waits for a message's web view to lay out.
    private static let layoutTimeout: Duration = .seconds(5)

    /// The search that is parked until one message's web view has laid out.
    private struct LayoutWait {
        let id: Int
        let messageID: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private var views: [String: WKWebView] = [:]
    private var readable: Set<String> = []
    private var currentID: String?
    private var search: Task<Void, Never>?
    /// A typed query that has not been searched yet.
    private var pendingQuery: Task<Void, Never>?
    private var layoutWait: LayoutWait?
    private var lastWaitID = 0
    private var searchableText: [String: String] = [:]
    /// `searchableText` folded for matching, filled in when a search first reads it.
    private var foldedText: [String: String] = [:]
    private var versions: [String: ReaderBodyVersion] = [:]

    /// Every rendered message reports its text here, whether or not Find is
    /// ever opened, so the text is stored as it is and folded on first use.
    func setSearchableText(_ text: String, for messageID: String) {
        searchableText[messageID] = text
        foldedText[messageID] = nil
    }

    func discardSourceText() {
        hide()
        searchableText.removeAll(); foldedText.removeAll(); versions.removeAll()
    }

    func prepareSearch(messages: [MessageDetail]) async {
        for message in messages {
            guard !Task.isCancelled, let body = message.body else { continue }
            let version = ReaderBodyVersion(body)
            guard versions[message.id] != version else { continue }
            guard let text = try? await ReaderPreparedCache.shared.searchableText(body), !Task.isCancelled else { return }
            setSearchableText(text, for: message.id)
            versions[message.id] = version
        }
        if isVisible, !query.isEmpty { find(forward: true) }
    }

    func show() {
        isVisible = true
        focusRequest += 1
    }

    func hide() {
        pendingQuery?.cancel()
        pendingQuery = nil
        search?.cancel()
        isVisible = false
        cameUpEmpty = false
        currentID = nil
        requestedMessageID = nil
        for view in views.values { clearSelection(in: view) }
    }

    func register(_ view: WKWebView, for messageID: String) {
        views[messageID] = view
        readable.remove(messageID)
    }

    func didBecomeReadable(_ messageID: String) {
        readable.insert(messageID)
        if let layoutWait, layoutWait.messageID == messageID, views[messageID] != nil { endLayoutWait(layoutWait.id) }
    }

    func unregister(_ view: WKWebView) {
        for (id, existing) in views where existing === view { readable.remove(id) }
        views = views.filter { $0.value !== view }
    }

    /// A changed query starts over from the top of the current message, once
    /// typing pauses.
    func queryChanged() {
        pendingQuery?.cancel()
        pendingQuery = nil
        search?.cancel()
        if let currentID, let view = views[currentID] { clearSelection(in: view) }
        guard !query.isEmpty else {
            cameUpEmpty = false
            return
        }
        pendingQuery = Task { [weak self] in
            try? await Task.sleep(for: Self.queryDelay)
            guard !Task.isCancelled, let self else { return }
            pendingQuery = nil
            start(steps: [true])
        }
    }

    func find(forward: Bool) {
        // Return or a step button can arrive before a typed query has been
        // searched. That search still runs first, so the step lands on the
        // match it would have reached without the delay.
        start(steps: pendingQuery == nil ? [forward] : [true, forward])
    }

    /// Runs one search per step, each from where the one before it stopped.
    private func start(steps: [Bool]) {
        pendingQuery?.cancel()
        pendingQuery = nil
        search?.cancel()
        let query = query
        guard !query.isEmpty else {
            cameUpEmpty = false
            return
        }
        let ordered = candidates(for: query)
        guard !ordered.isEmpty else {
            cameUpEmpty = true
            return
        }
        search = Task { [weak self] in
            for forward in steps {
                guard let self, await self.step(forward: forward, query: query, in: ordered) else { return }
            }
        }
    }

    /// The messages that can hold a match, in reading order. A missing index
    /// is unknown, never evidence that a message cannot match. This keeps
    /// Find correct while bodies are still hydrating.
    private func candidates(for query: String) -> [String] {
        guard let firstWord = query.split(whereSeparator: \.isWhitespace).first else { return order }
        let word = Self.folded(String(firstWord))
        guard !word.isEmpty else { return order }
        return order.filter { id in
            guard let text = searchableText[id] else { return true }
            let folded = foldedText[id] ?? Self.folded(text)
            foldedText[id] = folded
            return folded.range(of: word, options: .literal) != nil
        }
    }

    /// Case and diacritics are folded once per text, so each search is a
    /// plain substring test. Both sides are precomposed afterwards, because
    /// a literal test does not treat canonically equal text as equal.
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    /// Selects the next or previous match. False when nothing matched or the
    /// search was cancelled.
    private func step(forward: Bool, query: String, in ordered: [String]) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = false
        var index = ordered.firstIndex { $0 == currentID } ?? (forward ? 0 : ordered.count - 1)
        // One pass more than there are messages: the starting one is
        // searched again from its edge once its selection is cleared.
        for _ in 0...ordered.count {
            guard !Task.isCancelled else { return false }
            let id = ordered[index]
            requestedMessageID = id
            requestRevision &+= 1
            // Scrolling materializes only the candidate body, not the
            // entire expanded conversation. Wait for its first layout.
            await waitForLayout(of: id)
            guard !Task.isCancelled else { return false }
            guard let view = views[id], readable.contains(id) else { cameUpEmpty = false; return false }
            let result = try? await view.find(query, configuration: configuration)
            guard !Task.isCancelled else { return false }
            if result?.matchFound == true {
                currentID = id
                cameUpEmpty = false
                await reveal(in: view)
                return true
            }
            clearSelection(in: view)
            index = (index + (forward ? 1 : ordered.count - 1)) % ordered.count
        }
        cameUpEmpty = true
        return false
    }

    /// Returns when the message's web view has laid out, the search is
    /// cancelled, or `layoutTimeout` passes. `didBecomeReadable` ends the wait.
    private func waitForLayout(of messageID: String) async {
        guard views[messageID] == nil || !readable.contains(messageID) else { return }
        lastWaitID &+= 1
        let waitID = lastWaitID
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.layoutTimeout)
            guard !Task.isCancelled else { return }
            self?.endLayoutWait(waitID)
        }
        defer { timeout.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                // One search runs at a time. A cancelled one that is still
                // parked here leaves before the next takes its place.
                endLayoutWait()
                layoutWait = LayoutWait(id: waitID, messageID: messageID, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endLayoutWait(waitID) }
        }
    }

    /// Resumes the parked search. With an ID, only if that wait is still the parked one.
    private func endLayoutWait(_ id: Int? = nil) {
        guard let wait = layoutWait, id == nil || wait.id == id else { return }
        layoutWait = nil
        wait.continuation.resume()
    }

    /// WebKit selects the match, and the message's web view is as tall as its
    /// content, so the conversation's scroll view does the scrolling.
    private func reveal(in view: WKWebView) async {
        let script = """
            (() => {
              const selection = getSelection();
              if (!selection || selection.rangeCount === 0) return null;
              const box = selection.getRangeAt(0).getBoundingClientRect();
              return [box.top, box.height];
            })()
            """
        guard let value = try? await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient),
              let box = value as? [NSNumber], box.count == 2 else { return }
        let top = CGFloat(box[0].doubleValue)
        let height = CGFloat(box[1].doubleValue)
        let y = view.isFlipped ? top : view.bounds.height - top - height
        view.scrollToVisible(NSRect(x: 0, y: y - Tokens.Space.s8, width: 1, height: height + Tokens.Space.s16))
    }

    private func clearSelection(in view: WKWebView) {
        view.evaluateJavaScript("getSelection()?.removeAllRanges()", in: nil, in: .defaultClient) { _ in }
    }
}

/// The bar above the conversation: the search field, Previous and Next, and
/// Done. Return finds the next match and Esc closes the bar.
struct ReaderFindBar: View {
    @Bindable var model: ReaderFindModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            TextField("Find in Conversation", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit { model.find(forward: true) }
                .frame(maxWidth: Tokens.Layout.searchMaxWidth)
            Text("Not Found")
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(model.cameUpEmpty ? 1 : 0)
                .ternAnimation(value: model.cameUpEmpty, duration: Tokens.Motion.fast)
                .accessibilityHidden(!model.cameUpEmpty)
            Spacer(minLength: 0)
            ControlGroup {
                Button("Previous", systemImage: "chevron.up") { model.find(forward: false) }
                    .help("Previous match")
                Button("Next", systemImage: "chevron.down") { model.find(forward: true) }
                    .help("Next match")
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            .disabled(model.query.isEmpty)
            Button("Done") { model.hide() }
        }
        .controlSize(.small)
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand { model.hide() }
        .onAppear { isFieldFocused = true }
        .onChange(of: model.focusRequest) { _, _ in isFieldFocused = true }
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in conversation")
    }
}
