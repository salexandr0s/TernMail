import MailStore
import SwiftUI

/// Uses the same sidebar as Mail while giving the library the full detail area.
struct AttachmentLibraryDestination: View {
    @Environment(AppModel.self) private var app
    @State private var model: AttachmentLibraryModel
    @Bindable var toolbar: AttachmentLibraryToolbarState
    let mailbox: MailboxModel

    init(mailbox: MailboxModel, toolbar: AttachmentLibraryToolbarState) {
        self.mailbox = mailbox
        self.toolbar = toolbar
        _model = State(initialValue: AttachmentLibraryModel(mailbox: mailbox))
    }

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
        .onChange(of: app.accountsNeedingSignIn, initial: true) { _, ids in model.unavailableAccountIDs = ids }
        .onChange(of: mailbox.accounts.map(\.account.id)) { _, ids in
            if let key = model.sourceThreadKey, !ids.contains(key.accountID) { model.sourceThreadKey = nil }
            model.previewURL = nil
        }
        .sheet(isPresented: Binding(get: { model.sourceThreadKey != nil }, set: { if !$0 { model.sourceThreadKey = nil } })) {
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
        let isPresented = mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID
        ZStack {
            content
                .opacity(isPresented ? 0 : 1)
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)
            if isPresented { AttachmentLibraryDestination(mailbox: mailbox, toolbar: toolbar) }
        }
    }
}
