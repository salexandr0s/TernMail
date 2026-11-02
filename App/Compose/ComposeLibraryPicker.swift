import SwiftUI

/// A bounded native library keeps saved items visible beside the New command.
struct ComposeLibraryPicker: View {
    struct Item: Identifiable {
        let id: String
        let name: String
    }

    let title: String
    let newItemLabel: String
    let symbol: String
    let identifierPrefix: String
    let items: [Item]
    @Binding var selection: String?
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s3) {
                Text(title).font(.callout.weight(.semibold))
                Text(items.count.formatted()).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: Tokens.Space.s2)
                Button("New", systemImage: "plus", action: onNew)
                    .controlSize(.small)
                    .help(newItemLabel)
                    .accessibilityLabel(newItemLabel)
                    .accessibilityIdentifier(identifierPrefix + "-new")
            }
            if items.isEmpty {
                Text("No saved items yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, Tokens.Space.s2)
            } else {
                List(selection: $selection) {
                    ForEach(items) { item in
                        Button { selection = item.id } label: {
                            HStack(spacing: Tokens.Space.s2) {
                                Label(item.name, systemImage: symbol)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if selection == item.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.name)
                        .accessibilityIdentifier(identifierPrefix + "-selection." + item.id)
                        .tag(item.id)
                    }
                }
                .listStyle(.inset)
                .frame(height: min(Tokens.Layout.quoteMaxHeight, CGFloat(items.count) * Tokens.Space.s10 + Tokens.Space.s2))
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifierPrefix + "-selection")
            }
        }
    }
}
