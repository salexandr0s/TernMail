import SwiftUI

struct SidebarFooter<Status: View, Details: View>: View {
    let accessibilityPrefix: String
    private let status: Status
    private let details: Details

    init(accessibilityPrefix: String = "sidebar", @ViewBuilder status: () -> Status,
         @ViewBuilder details: () -> Details) {
        self.accessibilityPrefix = accessibilityPrefix
        self.status = status()
        self.details = details()
    }

    var body: some View {
        VStack(spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s2) {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: Tokens.Control.icon))
                        .foregroundStyle(.primary)
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
                }
                .buttonStyle(.borderless)
                .background(Color.primary.opacity(Tokens.Opacity.hover), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .ternOutline(radius: Tokens.Radius.md, style: .contrastOnly)
                .ternHover(radius: Tokens.Radius.md)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("\(accessibilityPrefix).settings")

                status
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .accessibilityIdentifier("\(accessibilityPrefix).syncStatus")
            }

            details
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
    }
}

extension SidebarFooter where Details == EmptyView {
    init(accessibilityPrefix: String = "sidebar", @ViewBuilder status: () -> Status) {
        self.init(accessibilityPrefix: accessibilityPrefix, status: status, details: { EmptyView() })
    }
}
