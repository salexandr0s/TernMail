import MailStore
import SwiftUI

struct SidebarView: View {
    @Bindable var mailbox: MailboxModel

    var body: some View {
        List(selection: $mailbox.selectedLabelID) {
            Section("Mailboxes") {
                ForEach(SystemMailbox.all) { box in
                    Label(box.title, systemImage: box.systemImage)
                        .badge(mailbox.label(id: box.id)?.threadsUnread ?? 0)
                        .tag(box.id as String?)
                    if box.id == SystemLabel.draft, mailbox.showsOutbox {
                        Label("Outbox", systemImage: "tray.and.arrow.up")
                            .badge(mailbox.outbox.count)
                            .tag(MailboxModel.outboxID as String?)
                    }
                }
            }
            Section {
                OutlineGroup(LabelNode.outline(mailbox.userLabels), children: \.children) { node in
                    LabelRow(mailbox: mailbox, node: node)
                }
            } header: {
                HStack {
                    Text("Labels")
                    Spacer()
                    Button {
                        mailbox.showNewLabel()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Label")
                    .accessibilityLabel("New Label")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            SyncStatusView(mailbox: mailbox)
        }
        .sheet(item: $mailbox.labelEditor) { request in
            LabelEditorSheet(
                title: Self.editorTitle(request),
                saveTitle: Self.editorSaveTitle(request),
                draft: request.draft,
                parentChoices: mailbox.parentChoices(for: Self.editedLabel(request)),
                validate: { mailbox.labelNameProblem($0, renaming: Self.editedLabel(request)?.id) },
                onSave: { mailbox.saveLabel($0, for: request) },
                onCancel: { mailbox.labelEditor = nil }
            )
        }
        .confirmationDialog(
            "Delete the label “\(mailbox.labelToDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { mailbox.labelToDelete != nil },
                set: { if !$0 { mailbox.labelToDelete = nil } }
            )
        ) {
            Button("Delete Label", role: .destructive) { mailbox.deleteConfirmedLabel() }
        } message: {
            Text("Conversations keep their other labels. Gmail can't restore a deleted label, so this can't be undone.")
        }
    }

    private static func editedLabel(_ request: MailboxModel.LabelEditorRequest) -> LabelRecord? {
        if case .edit(let label) = request.kind { return label }
        return nil
    }

    private static func editorTitle(_ request: MailboxModel.LabelEditorRequest) -> String {
        editedLabel(request) == nil ? "New Label" : "Edit Label"
    }

    private static func editorSaveTitle(_ request: MailboxModel.LabelEditorRequest) -> String {
        editedLabel(request) == nil ? "Create" : "Save"
    }
}

/// A user label in the sidebar outline. A label Gmail hasn't created yet is
/// dimmed and can't be selected.
private struct LabelRow: View {
    let mailbox: MailboxModel
    let node: LabelNode

    var body: some View {
        let label = node.label
        let isPending = LabelRules.isTemporary(label.id)
        Label {
            Text(node.title)
                .help(label.name)
        } icon: {
            Image(systemName: "tag")
                .foregroundStyle(Color(gmailHex: label.backgroundColor) ?? .secondary)
        }
        .badge(label.threadsUnread ?? 0)
        .opacity(isPending ? 0.5 : 1)
        .selectionDisabled(isPending)
        .tag(label.id as String?)
        .accessibilityLabel(isPending ? "\(label.name), waiting for Gmail" : label.name)
        .contextMenu {
            Button("Edit Label…") { mailbox.showEditLabel(label) }
            Button("Delete Label…") { mailbox.labelToDelete = label }
        }
    }
}

/// User labels as an outline. Gmail stores nesting in the name, so
/// "Work/Clients" sits under "Work" when that label exists. A label whose
/// parent doesn't exist shows at the top level under its full name.
struct LabelNode: Identifiable, Equatable {
    let label: LabelRecord
    /// The name below the parent, or the full name at the top level.
    let title: String
    /// Nil for a label with nothing nested under it, as `OutlineGroup` expects.
    var children: [LabelNode]?

    var id: String { label.id }

    static func outline(_ labels: [LabelRecord]) -> [LabelNode] {
        let sorted = labels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let names = Set(sorted.map(\.name))
        // The nearest existing ancestor of each label, by full name.
        func parent(of name: String) -> String? {
            var path = name
            while let slash = path.lastIndex(of: "/") {
                path = String(path[..<slash])
                if names.contains(path) { return path }
            }
            return nil
        }
        let children = Dictionary(grouping: sorted) { parent(of: $0.name) ?? "" }
        func nodes(under parentName: String?) -> [LabelNode] {
            (children[parentName ?? ""] ?? []).map { label in
                let title = parentName.map { String(label.name.dropFirst($0.count + 1)) } ?? label.name
                let nested = nodes(under: label.name)
                return LabelNode(label: label, title: title, children: nested.isEmpty ? nil : nested)
            }
        }
        return nodes(under: nil)
    }
}

private struct SyncStatusView: View {
    let mailbox: MailboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            switch mailbox.syncStatus {
            case .syncing:
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.mini)
                    Text("Checking for mail…")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { mailbox.syncNow() }
                    .buttonStyle(.link)
            case .idle:
                if let date = mailbox.lastSyncedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated \(date.formatted(.relative(presentation: .named)))")
                    }
                }
            }
            Text(mailbox.account.email)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(mailbox.account.email)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s3)
    }
}

extension Color {
    /// Gmail label colors arrive as "#rrggbb".
    init?(gmailHex hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
