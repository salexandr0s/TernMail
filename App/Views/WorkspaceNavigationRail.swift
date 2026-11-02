import MailStore
import SwiftUI

extension EnvironmentValues {
    @Entry var showsWorkspaceRail = false
    @Entry var workspaceWindowWidth: CGFloat? = nil
}

/// Global destinations stay separate from a page's folders and filters.
struct WorkspaceNavigationRail: View {
    let section: WorkspaceSection
    let onSelect: (WorkspaceSection) -> Void

    var body: some View {
        VStack(spacing: Tokens.Space.s3) {
            Text("Tern")
                .font(.title3.bold())
                .padding(.vertical, Tokens.Space.s4)
                .accessibilityAddTraits(.isHeader)

            ForEach(WorkspaceSection.allCases) { destination in
                Button { onSelect(destination) } label: {
                    VStack(spacing: Tokens.Space.s2) {
                        Image(systemName: destination.systemImage)
                            .font(.system(size: Tokens.Workspace.destinationIcon, weight: .medium))
                            .symbolVariant(section == destination ? .fill : .none)
                        Text(destination.title)
                            .font(.caption.weight(section == destination ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Tokens.Workspace.destinationHeight)
                    .foregroundStyle(section == destination ? Color.accentColor : .primary)
                    .background(section == destination ? Color.accentColor.opacity(Tokens.Opacity.tint) : .clear,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                    .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                }
                .buttonStyle(.plain)
                .ternOutline(radius: Tokens.Radius.lg, style: .contrastOnly)
                .ternHover(radius: Tokens.Radius.lg)
                .help(destination.title)
                .accessibilityLabel(destination.title)
                .accessibilityAddTraits(section == destination ? .isSelected : [])
                .accessibilityIdentifier("workspace.rail.\(destination.rawValue)")
            }

            Spacer(minLength: Tokens.Space.s4)

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(maxWidth: .infinity)
                    .frame(height: Tokens.Control.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
            .accessibilityIdentifier("workspace.rail.settings")
        }
        .padding(.horizontal, Tokens.Space.s2)
        .padding(.bottom, Tokens.Space.s4)
        .frame(width: Tokens.Workspace.railWidth)
        .frame(maxHeight: .infinity)
        .background(Tokens.Surface.muted)
        .overlay(alignment: .trailing) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace")
    }
}

extension WorkspaceSection {
    @MainActor func select(in app: AppModel, mailbox: MailboxModel) {
        switch self {
        case .mail:
            app.destination = .mail
            if mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID { mailbox.go(to: SystemLabel.inbox) }
        case .calendar:
            app.destination = .calendar
        case .attachments:
            app.destination = .mail
            mailbox.selectedMailbox = .combined(AttachmentLibraryModel.mailboxID)
        }
    }
}
