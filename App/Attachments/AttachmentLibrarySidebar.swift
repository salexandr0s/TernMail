import MailStore
import SwiftUI

/// Library scope is independent of Mail's selected mailbox and account profile.
struct AttachmentLibrarySidebar: View {
    @Bindable var model: AttachmentLibraryModel
    var onSelect: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.top, Tokens.Space.s5)
                .padding(.bottom, Tokens.Space.s3)

            List {
                Section("Accounts") {
                    scopeButton("All accounts", symbol: "tray.full", selected: model.accountID.isEmpty) {
                        model.accountID = ""
                    }
                    .accessibilityIdentifier("attachments.sidebar.allAccounts")
                    ForEach(model.availableAccounts) { account in
                        let title = model.mailbox.accountTitle(account)
                        scopeButton(title, subtitle: title == account.email ? nil : account.email,
                            symbol: "person.crop.circle", selected: model.accountID == account.id) {
                            model.accountID = account.id
                        }
                        .help(account.email)
                        .accessibilityIdentifier("attachments.sidebar.account.\(account.id)")
                    }
                }
                Section("Categories") {
                    scopeButton("All categories", symbol: "square.grid.2x2", selected: model.category == nil) {
                        model.category = nil
                    }
                    .accessibilityIdentifier("attachments.sidebar.allCategories")
                    ForEach(AttachmentCategory.allCases, id: \.self) { category in
                        scopeButton(category.title, symbol: symbol(for: category), selected: model.category == category) {
                            model.category = category
                        }
                        .accessibilityIdentifier("attachments.sidebar.category.\(category.rawValue)")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background { SidebarMaterial() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachment library navigation")
    }

    private func scopeButton(_ title: String, subtitle: String? = nil, symbol: String, selected: Bool,
                             action: @escaping () -> Void) -> some View {
        Button {
            action()
            onSelect()
        } label: {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: symbol)
                    .frame(width: Tokens.Control.icon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                    Text(title).font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Tokens.Space.s2)
            .padding(.vertical, Tokens.Space.s2)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .background(selected ? Color.accentColor.opacity(Tokens.Opacity.tint) : .clear,
                in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func symbol(for category: AttachmentCategory) -> String {
        switch category {
        case .uncategorized: "tray"
        case .invoice: "doc.text"
        case .receipt: "receipt"
        case .contract: "signature"
        case .ticket: "ticket"
        case .other: "doc.on.doc"
        }
    }
}

/// Observe the retained model only inside the popup, outside the toolbar declaration.
struct AttachmentLibrarySidebarPopover: View {
    let toolbar: AttachmentLibraryToolbarState

    var body: some View {
        if let model = toolbar.sidebarModel {
            AttachmentLibrarySidebar(model: model) { toolbar.isPopoverPresented = false }
                .frame(width: Tokens.Layout.sidebarWidth, height: Tokens.Layout.windowMinHeight)
        }
    }
}
