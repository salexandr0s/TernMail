import AppIntents
import AppKit
import MailStore
import MessageContent
import SwiftUI

@main
struct TernApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        // One mailbox window: selection and undo live in the shared mailbox model.
        Window("Tern", id: RootView.sceneID) {
            Group {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-audit-avatars"),
                   ProcessInfo.processInfo.arguments.contains("--ui-audit") {
                    AvatarAuditFixtures()
                } else { RootView() }
#else
                RootView()
#endif
            }
                .focusedSceneValue(\.isMainWindow, true)
                .modifier(MailURLHandling())
                .environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
                .task { await model.start() }
        }
        .defaultSize(width: Tokens.Layout.windowWidth, height: Tokens.Layout.windowHeight)
        // The catalog's shortcut goes on the scene's own Window ▸ Tern item.
        .keyboardShortcut(ShortcutCatalog.mainWindow.shortcut)
        .commands { MailCommands(app: model) }

        WindowGroup("Conversation", id: ConversationWindow.sceneID, for: MailLink.self) { $link in
            ConversationWindow(link: link).environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Layout.readableWidth, height: Tokens.Layout.shortcutsHeight)
        .commandsRemoved()

        Window("Unsubscribe", id: UnsubscribeWindow.sceneID) {
            UnsubscribeWindow().environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Analytics.contentWidth, height: Tokens.Layout.windowHeight)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)

        WindowGroup("Analytics", id: MailAnalyticsWindow.sceneID, for: MailAnalyticsRoute.self) { $route in
            MailAnalyticsWindow(route: route).environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Analytics.windowWidth, height: Tokens.Analytics.windowHeight)
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        WindowGroup("Original Message", id: OriginalMessageWindow.sceneID, for: MailLink.self) { $link in
            OriginalMessageWindow(link: link).environment(model)
        }
        .defaultSize(width: Tokens.Layout.readableWidth, height: Tokens.Layout.shortcutsHeight)
        .commandsRemoved()

        // One window per local draft. Opening a draft that has a window brings it forward.
        WindowGroup("New Message", id: ComposeWindow.sceneID, for: String.self) { $localDraftID in
            ComposeWindow(localDraftID: $localDraftID)
                .environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Layout.composeWidth, height: Tokens.Layout.composeHeight)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        // File > New Message replaces the New Window item this scene would add.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Settings.width, height: Tokens.Settings.height)
        .windowResizability(.contentMinSize)

        Window("Assistant", id: AssistantWindow.sceneID) {
            AssistantWindow(model: model.assistant, onOpenSource: model.openAssistantSource)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Layout.readableWidth, height: Tokens.Layout.shortcutsHeight)
        .windowResizability(.contentMinSize)
        // The catalog's shortcut goes on the scene's own Window ▸ Assistant item.
        .keyboardShortcut(ShortcutCatalog.assistant.shortcut)

        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.sceneID) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
        // Help opens it, so the Window menu doesn't list it too.
        .commandsRemoved()
    }
}

/// Owns the app model, so quitting can store open drafts and send messages
/// still waiting to go.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// The quit under way, so choosing Quit again meanwhile starts nothing new.
    private let quitRequests = QuitRequests()

    override init() {
        super.init()
        // Shortcuts actions reach the mailbox through this dependency.
        AppDependencyManager.shared.add { [model = self.model] in model }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NavigationPerformance.shared.installInputMonitoring()
        MailNotificationRouter.shared.install()
        MailScriptingBridge.shared.bind(model)
        // The Info.plist NSServices entries call these handlers. NSApp keeps the provider.
        NSApp.servicesProvider = MailServices(app: model)
        NSUpdateDynamicServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click with every window closed brings the mailbox back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        model.showMainWindow()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let signedIn = model.mailbox != nil
        for (title, action, enabled) in [
            ("New Message", #selector(dockNewMessage), signedIn),
            ("Check for New Mail", #selector(dockCheckForNewMail), signedIn),
        ] as [(String, Selector, Bool)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("Inbox", #selector(dockShowInbox)), ("Calendar", #selector(dockShowCalendar))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = signedIn
            menu.addItem(item)
        }
        return menu
    }

    @objc private func dockNewMessage() { model.composeFromDock() }

    @objc private func dockCheckForNewMail() { model.mailbox?.syncNow() }

    @objc private func dockShowInbox() {
        model.showMainWindow()
        model.destination = .mail
        model.mailbox?.go(to: SystemLabel.inbox)
    }

    @objc private func dockShowCalendar() {
        model.showMainWindow()
        model.destination = .calendar
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where !model.auth.handleRedirect(url) { model.mailURLs.receive(url) }
    }

    /// Spotlight results and Handoff. SwiftUI hands these to the delegate even
    /// with every window closed, and skips view handlers once it returns true.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        model.continueActivity(userActivity)
    }

    #if DEBUG || TERN_PERFORMANCE
    /// Appearance checks affect only the synthetic audit app, never system preferences.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-audit") else { return }
        let highContrast = arguments.contains("--ui-audit-contrast")
        if arguments.contains("--ui-audit-light") {
            NSApp.appearance = NSAppearance(named: highContrast ? .accessibilityHighContrastAqua : .aqua)
        } else if arguments.contains("--ui-audit-dark") {
            NSApp.appearance = NSAppearance(named: highContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
        }
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let started = quitRequests.begin { [self] in
            await reviewQuit()
        } reply: { shouldQuit in
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        // A quit already under way gives the answer.
        return started ? .terminateLater : .terminateCancel
    }

    /// Stores open drafts, then sends what waits in the Outbox. A draft that
    /// can't be stored, or an Outbox that can't be read, stops the quit and
    /// asks whether to try again, stay open or quit anyway.
    private func reviewQuit() async -> Bool {
        // Before anything stops, so staying open leaves Tern as it was.
        if case .stayOpen = await attempt({ try await self.model.storeOpenDrafts() }) { return false }
        await model.prepareToQuit()
        let shouldQuit = await reviewOutbox()
        if !shouldQuit { await model.cancelQuit() }
        return shouldQuit
    }

    /// Sends the messages waiting in the Outbox, and asks before quitting
    /// with one that didn't go.
    private func reviewOutbox() async -> Bool {
        let waiting: Set<String>
        switch await attempt({ try await self.model.sendingDraftIDs() }) {
        case .done(let ids): waiting = ids
        case .quitAnyway: return true
        case .stayOpen: return false
        }
        guard !waiting.isEmpty else { return true }
        if await model.sendWaitingMessages() { return true }
        switch await attempt({ try await self.model.sendingDraftIDs().count }) {
        case .done(let unsent) where unsent > 0: return Self.confirmQuit(unsent: unsent)
        case .done: break
        case .quitAnyway: return true
        case .stayOpen: return false
        }
        // Nothing waits any more, so Gmail refused what didn't go out.
        switch await attempt({ try await self.model.refusedDraftCount(among: waiting) }) {
        case .done(let refused): return refused == 0 || Self.confirmQuit(refused: refused)
        case .quitAnyway: return true
        case .stayOpen: return false
        }
    }

    private enum QuitStep<Value> {
        case done(Value)
        case quitAnyway
        case stayOpen
    }

    /// Runs `step` until it works or the person stops trying.
    private func attempt<Value>(_ step: () async throws -> Value) async -> QuitStep<Value> {
        while true {
            do {
                return .done(try await step())
            } catch {
                switch Self.ask(after: error) {
                case .alertFirstButtonReturn: continue
                case .alertThirdButtonReturn: return .quitAnyway
                default: return .stayOpen
                }
            }
        }
    }

    /// Says why quitting stopped, and returns the button chosen: Try Again,
    /// Stay Open or Quit Anyway.
    private static func ask(after error: any Error) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        if case .unsavedDrafts(let titles)? = error as? AppModel.QuitProblem {
            alert.messageText = titles.count == 1 ? "Couldn't Save Your Draft" : "Couldn't Save \(titles.count) Drafts"
            let names = ListFormatter.localizedString(byJoining: titles.map { "“\($0)”" })
            alert.informativeText = "Tern couldn't save everything in \(names). The message window shows what went wrong. "
                + "If you quit now, the unsaved changes are lost."
        } else {
            alert.messageText = "Couldn't Check the Outbox"
            alert.informativeText = "Tern couldn't read the messages waiting to send. "
                + "If you quit now, any still waiting go out the next time you open Tern."
        }
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Stay Open").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
        return alert.runModal()
    }

    /// Asks before quitting with a refused message, which is open again and says why.
    private static func confirmQuit(refused count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Gmail didn't send your message" : "Gmail didn't send \(count) messages"
        alert.informativeText = count == 1
            ? "Review the error in the reopened message. If you quit, it stays unsent in the Outbox."
            : "Review the errors in the reopened messages. If you quit, they stay unsent in the Outbox."
        alert.addButton(withTitle: "Stay Open").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func confirmQuit(unsent count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Quit without sending your message?" : "Quit without sending \(count) messages?"
        alert.informativeText = "Tern can't reach Gmail. If you quit, "
            + (count == 1 ? "it will retry this message" : "it will retry these messages")
            + " the next time you open Tern."
        alert.addButton(withTitle: "Stay Open").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// One quit at a time. macOS asks again when Quit is chosen while an earlier
/// quit still stores drafts or sends, and that request must not start another.
@MainActor
final class QuitRequests {
    private(set) var isQuitting = false

    /// Runs `review` and gives its answer to `reply`. Returns false, starting
    /// nothing, while an earlier quit is still under way.
    func begin(_ review: @escaping @MainActor () async -> Bool, reply: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard !isQuitting else { return false }
        isQuitting = true
        Task { [self] in
            let shouldQuit = await review()
            isQuitting = false
            reply(shouldQuit)
        }
        return true
    }
}

/// Picks the screen for the current sign-in phase.
struct RootView: View {
    /// The mailbox window's scene.
    static let sceneID = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowPresentation = OnboardingWindowPresentation.Controller()

    var body: some View {
        content
            .background(OnboardingWindowPresentation(isPresented: model.onboarding.isPresented,
                                                     reduceMotion: reduceMotion, controller: windowPresentation,
                                                     isReady: windowRouteIsReady))
            .onAppear {
                model.openMainWindow = {
                    NSApp.activate()
                    openWindow(id: Self.sceneID)
                }
            }
    }

    private var windowRouteIsReady: Bool {
        // A startup failure must remain visible even before accounts are loaded.
        if case .failed = model.phase { return true }
        return model.onboarding.isResolved
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            openingState
        case .signedOut, .signInRequired, .signedIn:
            if model.onboarding.isPresented {
                OnboardingView()
            } else if let mailbox = model.mailbox {
                VStack(spacing: 0) {
                    AccountReconnectionBanner(app: model)
                    WorkspaceView(mailbox: mailbox)
                }
            } else {
                SignInView()
            }
        case .failed(let message):
            TernEmptyState(
                title: "Couldn't Open Your Mail",
                systemImage: "exclamationmark.triangle",
                message: message
            )
        }
    }

    private var openingState: some View {
        VStack(spacing: Tokens.Space.s4) {
            ProgressView()
                .controlSize(.small)
            Text("Opening your mail…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Surface.muted)
    }
}
