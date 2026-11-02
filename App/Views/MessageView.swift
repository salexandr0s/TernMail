import Diagnostics
import MailStore
import MessageContent
import SwiftUI
import WebKit

struct MessageView: View {
    let message: MessageDetail
    let blocker: WKContentRuleList?
    let isExpanded: Bool
    /// Keyboard navigation in the reader rests on this message.
    let isFocused: Bool
    let isReaderActive: Bool
    let retainsHiddenBody: Bool
    let bodyLoadFailed: Bool
    let requiredNetwork: Bool
    let bodyAvailableAt: ContinuousClock.Instant?
    let mailbox: MailboxModel
    let finder: ReaderFindModel
    let onVisible: () -> Void
    let onReadable: (NavigationCacheTier, ContinuousClock.Instant?) -> Void
    let compose: (MailboxModel.ComposeStart) -> Void
    let onRetry: () -> Void
    let reportSelection: (String) -> Void
    let onHoverLink: (String?) -> Void
    let onMarkUnreadFromHere: () -> Void
    let onToggle: () -> Void

    @State private var rendered: RenderedMessage?
    @State private var hasNoText = false
    @State private var hasShownNoText = false
    @State private var height: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var inlineResources = InlineResourceMap()
    /// Load Images was chosen for this message.
    @State private var loadsImages = false
    @State private var allowsSenderImages = false
    @State private var selectedText = ""
    @State private var activeBlocker: WKContentRuleList?
    @State private var resourceSnapshot: ReadingResourceSnapshot?
    @State private var resourcesAvailableAt: ContinuousClock.Instant?
    @State private var isInViewport = true
    @State private var preparationTier: NavigationCacheTier = .local
    @State private var requiredContentReadyAt: ContinuousClock.Instant?
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ReadingPreferences.blockImagesKey) private var blocksImages = true
    @AppStorage(ReadingPreferences.adaptDarkKey) private var adaptsDark = true
    @AppStorage(ReadingPreferences.lightBackgroundSendersKey) private var lightBackgroundSenders = ""
    @AppStorage(ReadingPreferences.textScaleKey) private var textScale = 1.0
    @AppStorage(ReadingPreferences.sizeKey) private var showsSize = false

    private struct RenderIdentity: Equatable {
        let accountID: String
        let messageID: String
        let body: ReaderBodyVersion?
        let resourceRevision: Int?
        let allowsImages: Bool
        let showsLight: Bool
        let adaptsDark: Bool
        let textScale: Double
        let isExpanded: Bool
        let isActive: Bool
        let isRealized: Bool
    }

    private var allowsImages: Bool { loadsImages || allowsSenderImages || !blocksImages }
    private var isRealized: Bool {
        isExpanded && ((isReaderActive && (isInViewport || finder.requestedMessageID == message.id)) || retainsHiddenBody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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
        .ternSurface(radius: Tokens.Radius.md)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .strokeBorder(Color.accentColor, lineWidth: Tokens.Border.focus)
                    .allowsHitTesting(false)
            }
        }
        .ternAnimation(value: isExpanded)
        .onScrollVisibilityChange(threshold: 0) { visible in
            isInViewport = visible
            if visible { onVisible() }
        }
        .task(id: isReaderActive && isRealized) {
            guard isReaderActive, isRealized else { return }
            let token = TernSignposts.begin(.readerResources)
            var received = false
            defer { if !received { TernSignposts.cancel(token) } }
            do {
                for try await snapshot in mailbox.cache.readingResources(messageID: message.id, accountID: message.record.accountID) {
                    guard !Task.isCancelled else { return }
                    if !received { TernSignposts.end(token); received = true }
                    resourcesAvailableAt = .now
                    resourceSnapshot = snapshot
                }
            } catch { /* Keep the last safely prepared body on a transient store error. */ }
        }
        .task(id: RenderIdentity(accountID: message.record.accountID, messageID: message.id, body: message.body.map(ReaderBodyVersion.init),
            resourceRevision: resourceSnapshot?.revision, allowsImages: allowsImages, showsLight: showsLightBackground, adaptsDark: adaptsDark,
            textScale: textScale, isExpanded: isExpanded, isActive: isReaderActive, isRealized: isRealized)) {
            await render()
        }
        .task(id: message.record.sender) {
            let allowed = try? await mailbox.accountStore?.allowedImageSenders(accountID: message.record.accountID)
            guard !Task.isCancelled else { return }
            allowsSenderImages = allowed?.contains(senderAddress.lowercased()) == true
        }
        .onChange(of: isExpanded) { _, expanded in if !expanded { selectedText = ""; onHoverLink(nil) } }
        .onChange(of: isRealized) { _, realized in
            if !realized {
                rendered = nil; resourceSnapshot = nil
                inlineResources = InlineResourceMap()
            }
        }
        .onChange(of: selectedText) { _, text in reportSelection(text) }
        .onDisappear { reportSelection(""); onHoverLink(nil) }
        .onChange(of: allowsImages) { _, _ in
            rendered = nil; selectedText = ""; onHoverLink(nil)
            ReaderPreparedCache.shared.invalidate(accountID: message.record.accountID, messageID: message.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: ReadingPreferences.imagePermissionChanged)) { change in
            guard change.userInfo?["account"] as? String == message.record.accountID,
                  change.userInfo?["sender"] as? String == senderAddress.lowercased(),
                  let allowed = change.userInfo?["allowed"] as? Bool else { return }
            allowsSenderImages = allowed
            // Blocking the sender's images ends Load Images too.
            if !allowed { loadsImages = false }
        }
    }

    private var header: some View {
        MessageHeader(message: message, mailbox: mailbox, isExpanded: isExpanded,
                      selectedText: selectedText, blockedTrackers: rendered?.blockedTrackers ?? 0,
                      showsSize: showsSize, compose: compose,
                      onMarkUnreadFromHere: onMarkUnreadFromHere, onToggle: onToggle) {
            senderMenuItems
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isRealized {
            Color.clear.frame(height: max(contentHeight, height, Tokens.Space.s5))
                .accessibilityHidden(true)
        } else if let rendered {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                if rendered.blockedRemoteImages > 0 {
                    RemoteImagesBar(sender: message.parsedSenderAddress, onLoad: { loadsImages = true }) {
                        mailbox.setImageSenderAllowed(true, address: senderAddress, accountID: message.record.accountID)
                    }
                }
                MessageWebView(html: rendered.html, blocker: activeBlocker ?? blocker, height: $height, resources: inlineResources,
                    adaptsDarkMode: adaptsDark && !showsLightBackground,
                    forcesLightAppearance: showsLightBackground,
                    isActive: isReaderActive,
                    onReadable: { retained in
                        finder.didBecomeReadable(message.id)
                        guard isReaderActive, isInViewport else { return }
                        onReadable(retained ? .retained : preparationTier, retained ? nil : requiredContentReadyAt)
                    },
                    onHover: onHoverLink, onSelectionChange: { selectedText = $0 },
                    onAddSelectionToTasks: app.tasks.isCreating ? nil : { text in
                        guard let request = EmailTaskRequest.selection(text, message: message,
                            accountEmail: mailbox.account(id: message.record.accountID)?.account.email) else { return }
                        app.showTasks()
                        Task { await app.tasks.add(request) }
                    },
                    onOpenMailLink: { app.mailURLs.receive($0) },
                    onCreate: { finder.register($0, for: message.id) },
                    onDismantle: { finder.unregister($0) })
                    .id(inlineResources.scope + ":\(showsLightBackground):\(adaptsDark)")
                    .frame(height: max(height, Tokens.Space.s5))
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                    .accessibilityLabel("Message from \(senderName)")
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                if newHeight > 0, abs(contentHeight - newHeight) >= 1 { contentHeight = newHeight }
            }
        } else if hasNoText {
            Text("This message has no text.")
                .foregroundStyle(.secondary)
                .onChange(of: isReaderActive, initial: true) { _, active in
                    if active, isInViewport {
                        onReadable(hasShownNoText ? .retained : preparationTier, hasShownNoText ? nil : requiredContentReadyAt)
                        hasShownNoText = true
                    }
                }
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
                .frame(minHeight: max(contentHeight, height))
        }
    }

    private var senderName: String { message.senderDisplayName }
    private var senderAddress: String { message.senderAddress }

    /// Light mail already reads as the sender made it; the choice matters in
    /// Dark. It's kept by address, so a sender without one isn't offered it.
    private var offersLightBackground: Bool { adaptsDark && colorScheme == .dark && message.parsedSenderAddress != nil }

    private var showsLightBackground: Bool {
        offersLightBackground && LightBackgroundSenders(storage: lightBackgroundSenders).contains(senderAddress)
    }

    /// The sender's reading choices, after the message commands.
    @ViewBuilder private var senderMenuItems: some View {
        if offersLightBackground || allowsSenderImages { Divider() }
        if offersLightBackground {
            Toggle("Show with Light Background", isOn: Binding(showsLightBackground) { isOn in
                var senders = LightBackgroundSenders(storage: lightBackgroundSenders)
                senders.set(isOn, for: senderAddress)
                lightBackgroundSenders = senders.storage
            })
        }
        if allowsSenderImages {
            Button("Block Images from Sender") {
                mailbox.setImageSenderAllowed(false, address: senderAddress, accountID: message.record.accountID)
            }
        }
    }

    /// Sanitizing can take a moment on large mail, so it runs off the main actor.
    /// Without the rule list that blocks remote loads, only text is shown.
    private func render() async {
        guard isReaderActive, isRealized else { return }
        guard let body = message.body else {
            rendered = nil
            hasNoText = false
            height = 0
            return
        }
        guard let snapshot = resourceSnapshot, let owner = mailbox.account(id: message.record.accountID) else { return }
        let readyAt = max(bodyAvailableAt ?? .now, resourcesAvailableAt ?? .now)
        let rules = await RemoteContentBlocker.ruleList(allowsRemoteImages: allowsImages)
        guard !Task.isCancelled else { return }
        activeBlocker = rules
        let key = ReaderPreparationKey(accountID: message.record.accountID, owner: ObjectIdentifier(owner), messageID: message.id,
            body: ReaderBodyVersion(body), resourcesRevision: snapshot.revision, allowsImages: allowsImages,
            textOnly: rules == nil, textScale: ReadingPreferences.textScale(textScale))
        let cache = ReaderPreparedCache.shared
        while !Task.isCancelled {
          let cached = cache.value(for: key)
          do {
            let result: PreparedReaderDocument
            if let cached { result = cached }
            else { result = try await cache.prepare(key: key, body: body, resources: snapshot.resources) }
            guard !Task.isCancelled else { return }
            requiredContentReadyAt = readyAt
            preparationTier = requiredNetwork ? .network : (cached == nil ? .local : .prepared)
            inlineResources = result.resources
            rendered = result.rendered
            if !hasNoText { hasShownNoText = false }
            hasNoText = result.rendered == nil
            finder.setSearchableText(result.searchableText, for: message.id)
            return
          } catch is CancellationError {
            // Another window can revoke this message while our policy stays
            // unchanged. A live consumer retries; cancelled selections exit.
            guard !Task.isCancelled, mailbox.account(id: message.record.accountID) === owner else { return }
            await Task.yield()
          } catch { return }
        }
    }
}

/// Sits above a message body while the message has remote images blocked.
/// Load Images shows them in this message; Always Load keeps them on for the
/// sender.
private struct RemoteImagesBar: View {
    /// The sender's address, when the From header has one.
    let sender: String?
    let onLoad: () -> Void
    let onAlwaysLoad: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s3) {
                summary
                Spacer(minLength: 0)
                actions
            }
            .padding(.vertical, Tokens.Space.s1_5)
            .padding(.leading, Tokens.Space.s3)
            .padding(.trailing, Tokens.Space.s1_5)
            // A narrow reader puts the buttons under the summary.
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                summary
                HStack(spacing: Tokens.Space.s2) { actions }
            }
            .padding(Tokens.Space.s3)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(Tokens.Opacity.hover), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .ternOutline(radius: Tokens.Radius.sm, style: .contrastOnly)
    }

    private var summary: some View {
        Label("Remote images blocked", systemImage: "eye.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var actions: some View {
        Button("Load Images", action: onLoad)
        if let sender {
            Menu {
                Button("Always Load from Sender", action: onAlwaysLoad)
            } label: {
                Label("Image settings", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help("Image settings for \(sender)")
            .accessibilityLabel("Image settings")
        }
    }
}
