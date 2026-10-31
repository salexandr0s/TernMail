import MailStore
import SwiftUI

/// Uses the same sidebar as Mail while giving the library the full detail area.
struct AttachmentLibraryDestination: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: AttachmentLibraryModel
    @Bindable var toolbar: AttachmentLibraryToolbarState
    private var mailbox: MailboxModel { model.mailbox }

    var body: some View {
        NavigationSplitView(columnVisibility: $toolbar.columnVisibility) {
            SidebarView(mailbox: mailbox)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: Tokens.Layout.sidebarMinWidth,
                    ideal: Tokens.Layout.sidebarWidth, max: Tokens.Layout.sidebarMaxWidth)
        } detail: {
            AttachmentLibraryView(model: model, onOpenSource: {}, searchFocusRequest: toolbar.searchFocusRequest)
        }
        .toolbar(removing: .sidebarToggle)
        .onDisappear { model.dismissPresentation() }
        .onChange(of: toolbar.searchText) { _, text in if model.search != text { model.search = text } }
        .onChange(of: model.search, initial: true) { _, text in if toolbar.searchText != text { toolbar.searchText = text } }
        .onChange(of: app.accountsNeedingSignIn, initial: true) { _, ids in model.unavailableAccountIDs = ids }
        .onChange(of: mailbox.accounts.map(\.account.id)) { _, ids in
            if let key = model.sourceThreadKey, !ids.contains(key.accountID) { model.sourceThreadKey = nil }
            model.previewURL = nil
        }
        .sheet(isPresented: $model.sourceThreadKey.isPresent()) {
            if let key = model.sourceThreadKey {
                VStack(spacing: 0) {
                    HStack {
                        Label("Original email", systemImage: "envelope")
                            .font(.headline)
                        Spacer()
                        Button("Done") { model.sourceThreadKey = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(Tokens.Space.s4)
                    Divider()
                    ThreadView(key: key, mailbox: mailbox)
                        .id(key)
                }
                .frame(width: Tokens.Layout.readableWidth, height: Tokens.Layout.windowMinHeight)
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
