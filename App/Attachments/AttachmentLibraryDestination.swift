import AppKit
import MailStore
import MessageContent
import SwiftUI

/// Uses the same sidebar as Mail while giving the library the full detail area.
struct AttachmentLibraryDestination: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AttachmentLibraryModel
    @Bindable var toolbar: AttachmentLibraryToolbarState
    /// Whether the library is in front. After its first use it stays mounted
    /// behind Mail, where it takes no input and observes no pages.
    let isActive: Bool
    private var mailbox: MailboxModel { model.mailbox }
    private var isReady: Bool { isActive && model.isPageReady }

    var body: some View {
        TernSidebarSplit(isPresented: toolbar.showsSidebar, sidebarWidth: $toolbar.sidebarWidth,
                         minimumWidth: Tokens.Layout.sidebarMinWidth, maximumWidth: toolbar.sidebarMaximumWidth) {
            SidebarView(mailbox: mailbox)
        } detail: {
            AttachmentLibraryView(model: model, viewMode: toolbar.viewMode, isActive: isActive,
                focusSearch: { toolbar.searchFocusRequest += 1 })
                .background {
                    VisibleContentProbe(kind: .workspace, isActive: isReady, revision: model.pagePresentationRevision)
                }
                .onChange(of: isReady, initial: true) { _, ready in
                    if ready { reportReady() }
                }
                .onChange(of: model.pagePresentationRevision) { _, _ in
                    if isReady { reportReady() }
                }
        }
        // Bound the native split below the toolbar before clipping its material.
        .padding(.top, Tokens.Border.hairline)
        .clipped()
        .onGeometryChange(for: Bool.self) { $0.size.width < Tokens.Layout.sidebarCompactWidth } action: {
            toolbar.updateNarrow($0)
        }
        .toolbar(removing: .sidebarToggle)
        .modifier(MailNoticeOverlay(mailbox: mailbox))
        .onDisappear { model.dismissPresentation(); toolbar.isPopoverPresented = false }
        .onChange(of: isActive) { _, active in
            if !active { model.dismissPresentation(); toolbar.isPopoverPresented = false }
        }
        .onChange(of: toolbar.searchText) { _, text in if model.search != text { model.search = text } }
        .onChange(of: model.search, initial: true) { _, text in if toolbar.searchText != text { toolbar.searchText = text } }
        .onChange(of: toolbar.sort) { _, sort in if model.sort != sort { model.sort = sort } }
        .onChange(of: toolbar.refreshRequest) { _, _ in
            guard !toolbar.isRefreshing else { return }
            toolbar.isRefreshing = true
            Task {
                defer { toolbar.isRefreshing = false }
                await model.refresh()
            }
        }
        .onChange(of: model.isWorking, initial: true) { _, working in toolbar.isWorking = working }
        .onChange(of: model.sort, initial: true) { _, sort in if toolbar.sort != sort { toolbar.sort = sort } }
        .onChange(of: app.accountsNeedingSignIn, initial: true) { _, ids in model.unavailableAccountIDs = ids }
        .onChange(of: mailbox.accounts.map(\.account.id)) { _, _ in model.previewURL = nil }
        .onChange(of: model.sourceLink) { _, link in
            guard let link else { return }
            model.sourceLink = nil
            openWindow(id: ConversationWindow.sceneID, value: link)
        }
    }

    private func reportReady() {
        guard app.destination == .mail, mailbox.showsAttachmentLibrary else { return }
        NavigationPerformance.shared.contentReady(.workspace, cacheTier: .retained)
    }
}

/// Keeps Mail's selection and pane sizes mounted while the library is visible.
struct AttachmentLibraryPresentation: ViewModifier {
    let mailbox: MailboxModel
    let toolbar: AttachmentLibraryToolbarState

    func body(content: Content) -> some View {
        AttachmentLibraryPresentationContent(mailbox: mailbox, toolbar: toolbar, content: content)
            .id(ObjectIdentifier(mailbox))
    }
}

/// Builds the library on its first use and keeps it behind Mail afterwards, as
/// the workspace keeps its other sections, so a later switch only shows it.
private struct AttachmentLibraryPresentationContent<Content: View>: View {
    @Environment(AppModel.self) private var app
    let mailbox: MailboxModel
    let toolbar: AttachmentLibraryToolbarState
    let content: Content
    @State private var model: AttachmentLibraryModel
    @State private var hasPresented = false

    init(mailbox: MailboxModel, toolbar: AttachmentLibraryToolbarState, content: Content) {
        self.mailbox = mailbox
        self.toolbar = toolbar
        self.content = content
        _model = State(initialValue: AttachmentLibraryModel(mailbox: mailbox))
    }

    var body: some View {
        let isPresented = app.destination == .mail && mailbox.showsAttachmentLibrary
        ZStack {
            content
                .opacity(isPresented ? 0 : 1)
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)
            if isPresented || hasPresented {
                AttachmentLibraryDestination(model: model, toolbar: toolbar, isActive: isPresented)
                    .opacity(isPresented ? 1 : 0)
                    .allowsHitTesting(isPresented)
                    .accessibilityHidden(!isPresented)
                    .disabled(!isPresented)
            }
        }
        .onChange(of: isPresented, initial: true) { _, shown in
            if shown { hasPresented = true }
        }
    }
}
