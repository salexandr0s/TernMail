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
    private var mailbox: MailboxModel { model.mailbox }

    var body: some View {
        HSplitView {
            if toolbar.showsSidebar {
                SidebarView(mailbox: mailbox)
                    .frame(minWidth: Tokens.Layout.sidebarMinWidth,
                        idealWidth: toolbar.sidebarWidth, maxWidth: Tokens.Layout.sidebarMaxWidth)
                    .background { AttachmentSidebarWidthProbe(toolbar: toolbar) }
            }
            AttachmentLibraryView(model: model, viewMode: toolbar.viewMode,
                focusSearch: { toolbar.searchFocusRequest += 1 })
                .background {
                    ZStack {
                        VisibleContentProbe(kind: .workspace, isActive: model.isPageReady,
                                            revision: model.pagePresentationRevision)
                        VisibleContentProbe(kind: .mailbox, isActive: model.isPageReady,
                                            revision: model.pagePresentationRevision)
                    }
                }
                .onChange(of: model.isPageReady, initial: true) { _, ready in
                    if ready { reportReady() }
                }
                .onChange(of: model.pagePresentationRevision) { _, _ in
                    if model.isPageReady { reportReady() }
                }
        }
        // Bound the native split below the toolbar before clipping its material.
        .padding(.top, Tokens.Border.hairline)
        .clipped()
        .onGeometryChange(for: Bool.self) { $0.size.width < Tokens.Layout.sidebarCompactWidth } action: {
            toolbar.updateCompact($0)
        }
        .toolbar(removing: .sidebarToggle)
        .modifier(MailNoticeOverlay(mailbox: mailbox))
        .onDisappear { model.dismissPresentation(); toolbar.isPopoverPresented = false }
        .onChange(of: toolbar.searchText) { _, text in if model.search != text { model.search = text } }
        .onChange(of: model.search, initial: true) { _, text in if toolbar.searchText != text { toolbar.searchText = text } }
        .onChange(of: toolbar.sort) { _, sort in if model.sort != sort { model.sort = sort } }
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
        guard app.destination == .mail, mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID else { return }
        NavigationPerformance.shared.contentReady(.workspace, cacheTier: .retained)
        NavigationPerformance.shared.contentReady(.mailbox, cacheTier: .retained)
    }
}

/// Restore the dragged width when AppKit inserts the sidebar into its split.
/// An ideal SwiftUI width alone lets that insertion fall back to the minimum.
private struct AttachmentSidebarWidthProbe: NSViewRepresentable {
    let toolbar: AttachmentLibraryToolbarState

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.widthToRestore = toolbar.sidebarWidth
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.toolbar = toolbar
        view.scheduleMeasurement()
    }

    final class Probe: NSView {
        weak var toolbar: AttachmentLibraryToolbarState?
        var widthToRestore: CGFloat?
        private var splitWidth: CGFloat?
        private var scheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleMeasurement() }
        override func layout() { super.layout(); scheduleMeasurement() }

        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                scheduled = false
                guard window != nil, let toolbar, toolbar.showsSidebar,
                      let divider = EnclosingSplitDivider(of: self) else { return }
                // Window resizing must not replace the user's dragged width.
                if let previous = splitWidth, abs(previous - divider.split.bounds.width) > 0.5 {
                    widthToRestore = toolbar.sidebarWidth
                }
                splitWidth = divider.split.bounds.width
                if let width = widthToRestore {
                    let lower = divider.split.minPossiblePositionOfDivider(at: divider.index)
                    let upper = divider.split.maxPossiblePositionOfDivider(at: divider.index)
                    guard width >= lower, width <= upper else { return }
                    divider.split.setPosition(width, ofDividerAt: divider.index)
                    widthToRestore = nil
                }
                let width = divider.pane.frame.width
                if width > 0, abs(toolbar.sidebarWidth - width) > 0.5 { toolbar.sidebarWidth = width }
            }
        }
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

/// Retains the last library page while its views and observations are offscreen.
private struct AttachmentLibraryPresentationContent<Content: View>: View {
    @Environment(AppModel.self) private var app
    let mailbox: MailboxModel
    let toolbar: AttachmentLibraryToolbarState
    let content: Content
    @State private var model: AttachmentLibraryModel

    init(mailbox: MailboxModel, toolbar: AttachmentLibraryToolbarState, content: Content) {
        self.mailbox = mailbox
        self.toolbar = toolbar
        self.content = content
        _model = State(initialValue: AttachmentLibraryModel(mailbox: mailbox))
    }

    var body: some View {
        let isPresented = app.destination == .mail && mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID
        ZStack {
            content
                .opacity(isPresented ? 0 : 1)
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)
            if isPresented { AttachmentLibraryDestination(model: model, toolbar: toolbar) }
        }
    }
}
