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

    private var views: [String: WKWebView] = [:]
    private var readable: Set<String> = []
    private var currentID: String?
    private var search: Task<Void, Never>?
    private var searchableText: [String: String] = [:]
    private var versions: [String: ReaderBodyVersion] = [:]

    func setSearchableText(_ text: String, for messageID: String) { searchableText[messageID] = text }

    func prepareSearch(messages: [MessageDetail]) async {
        for message in messages {
            guard !Task.isCancelled, let body = message.body else { continue }
            let version = ReaderBodyVersion(body)
            guard versions[message.id] != version else { continue }
            guard let text = try? await ReaderPreparedCache.shared.searchableText(body), !Task.isCancelled else { return }
            searchableText[message.id] = text
            versions[message.id] = version
        }
        if isVisible, !query.isEmpty { find(forward: true) }
    }

    func show() {
        isVisible = true
        focusRequest += 1
    }

    func hide() {
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

    func didBecomeReadable(_ messageID: String) { readable.insert(messageID) }

    func unregister(_ view: WKWebView) {
        for (id, existing) in views where existing === view { readable.remove(id) }
        views = views.filter { $0.value !== view }
    }

    /// A changed query starts over from the top of the current message.
    func queryChanged() {
        if let currentID, let view = views[currentID] { clearSelection(in: view) }
        find(forward: true)
    }

    func find(forward: Bool) {
        search?.cancel()
        let query = query
        guard !query.isEmpty else {
            cameUpEmpty = false
            return
        }
        // A missing index is unknown, never evidence that a message cannot
        // match. This keeps Find correct while bodies are still hydrating.
        let ordered = order.filter { id in
            guard let text = searchableText[id] else { return true }
            guard let firstWord = query.split(whereSeparator: \.isWhitespace).first else { return true }
            return text.range(of: String(firstWord), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        guard !ordered.isEmpty else {
            cameUpEmpty = true
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = false
        search = Task { [weak self] in
            guard let self else { return }
            var index = ordered.firstIndex { $0 == self.currentID } ?? (forward ? 0 : ordered.count - 1)
            // One pass more than there are messages: the starting one is
            // searched again from its edge once its selection is cleared.
            for _ in 0...ordered.count {
                guard !Task.isCancelled else { return }
                let id = ordered[index]
                requestedMessageID = id
                requestRevision &+= 1
                // Scrolling materializes only the candidate body, not the
                // entire expanded conversation. Wait for its first layout.
                var attempts = 0
                while (views[id] == nil || !readable.contains(id)), attempts < 500 {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(10))
                    attempts += 1
                }
                guard !Task.isCancelled else { return }
                guard let view = views[id], readable.contains(id) else { cameUpEmpty = false; return }
                let result = try? await view.find(query, configuration: configuration)
                guard !Task.isCancelled else { return }
                if result?.matchFound == true {
                    currentID = id
                    cameUpEmpty = false
                    await reveal(in: view)
                    return
                }
                clearSelection(in: view)
                index = (index + (forward ? 1 : ordered.count - 1)) % ordered.count
            }
            cameUpEmpty = true
        }
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
