import AppKit
import WebKit

/// Starts WebKit before the first message opens and keeps one message view
/// ready for the next. The spare has its own private data store and has
/// loaded only an empty page, so the message that takes it skips building a
/// view and starting a web process. A view a message has used never comes back.
@MainActor
enum MessageWebViewWarmup {
    /// How close the first message is to opening, as the message list sees it.
    enum Readiness: Equatable {
        /// The first list page has not arrived.
        case waiting
        /// The list has rows and none is selected.
        case listDelivered
        /// A conversation is selected and its message view comes next.
        case selected

        init(listHasRows: Bool, hasSelection: Bool) {
            self = hasSelection ? .selected : listHasRows ? .listDelivered : .waiting
        }
    }

    /// Building the spare blocks the main thread for about 50 ms, and longer
    /// the first time. It waits until nothing has been selected, typed,
    /// clicked or scrolled for this long.
    private static let idleDelay: Duration = .seconds(1)
    private static let emptyPage = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'">
        </head><body></body></html>
        """

    private static var isArmed = false
    private static var hasStartedWebKit = false
    private static var spare: ContentSizedWebView?
    private static var refill: Task<Void, Never>?
    private static var lastInteraction = ContinuousClock.now
    /// The view handed out last, until it lays out or goes away. No spare is
    /// built while its message is still opening.
    private static weak var opening: ContentSizedWebView?
    /// After memory pressure there is no spare until the next message opens.
    private static var isHeldBack = false
    /// Windows that have shown a message view.
    private static let readerWindows = NSHashTable<NSWindow>.weakObjects()
    // These last as long as the app does, like the spare they manage.
    private static var observers: [any NSObjectProtocol] = []
    private static var eventMonitor: Any?
    private static var pressure: (any DispatchSourceMemoryPressure)?

    static func start(for readiness: Readiness) {
        guard readiness != .waiting else { return }
        // The list or the selection has just changed.
        lastInteraction = .now
        arm()
        if readiness == .selected, !hasStartedWebKit {
            // The first message is opening and its view would start WebKit
            // anyway. Starting it here gives that view a head start.
            if spare == nil, isReaderWindowVisible { spare = makeSpare() }
        } else {
            scheduleRefill()
        }
    }

    /// The view for one message: the spare when there is one, otherwise a new
    /// view. Either way no message has used it.
    static func takeMessageView() -> ContentSizedWebView {
        arm()
        lastInteraction = .now
        hasStartedWebKit = true
        isHeldBack = false
        refill?.cancel()
        refill = nil
        let view = spare ?? MessageWebView.makeUnassignedView()
        spare = nil
        opening = view
        return view
    }

    static func messageViewBecameReadable(_ view: WKWebView?) {
        guard let view, view === opening else { return }
        opening = nil
        lastInteraction = .now
        scheduleRefill()
    }

    static func messageViewDismantled(_ view: WKWebView) {
        guard view === opening else { return }
        opening = nil
        scheduleRefill()
    }

    static func noteReaderWindow(_ window: NSWindow) {
        readerWindows.add(window)
    }

    private static func arm() {
        guard !isArmed else { return }
        isArmed = true
        Task {
            _ = await RemoteContentBlocker.ruleList()
            _ = await RemoteContentBlocker.ruleList(allowsRemoteImages: true)
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in readerWindowVisibilityChanged() }
            })
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { event in
            // AppKit invokes local event monitors synchronously on the main thread.
            MainActor.assumeIsolated { lastInteraction = .now }
            return event
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { Task { @MainActor in releaseForMemoryPressure() } }
        source.resume()
        pressure = source
    }

    /// The same test `ReaderWindowVisibility` applies to one window. Until a
    /// message has been shown the reader's window is not known, and any
    /// visible window counts.
    private static var isReaderWindowVisible: Bool {
        let known = readerWindows.allObjects
        return (known.isEmpty ? NSApp.windows : known).contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
    }

    private static func readerWindowVisibilityChanged() {
        if isReaderWindowVisible { scheduleRefill() } else { releaseSpare() }
    }

    private static func releaseForMemoryPressure() {
        isHeldBack = true
        releaseSpare()
    }

    private static func releaseSpare() {
        refill?.cancel()
        refill = nil
        spare?.stopLoading()
        spare = nil
    }

    private static var canHoldSpare: Bool {
        spare == nil && opening == nil && !isHeldBack && isReaderWindowVisible
    }

    private static func scheduleRefill() {
        guard isArmed, refill == nil, canHoldSpare else { return }
        refill = Task {
            repeat {
                try? await Task.sleep(for: idleDelay)
                guard !Task.isCancelled else { return }
            } while ContinuousClock.now - lastInteraction < idleDelay
            refill = nil
            guard canHoldSpare else { return }
            spare = makeSpare()
        }
    }

    private static func makeSpare() -> ContentSizedWebView {
        hasStartedWebKit = true
        let view = MessageWebView.makeUnassignedView()
        view.loadHTMLString(emptyPage, baseURL: nil)
        return view
    }

    #if TERN_TEST_SUPPORT
    /// A spare like the one kept here, for a test to inspect on its own.
    static func makeSpareForTesting() -> ContentSizedWebView { makeSpare() }

    /// Builds the spare at once instead of waiting for an idle moment.
    static func refillNowForTesting() {
        if spare == nil { spare = makeSpare() }
    }

    static func holdsForTesting(_ view: WKWebView) -> Bool { spare === view }
    #endif
}
