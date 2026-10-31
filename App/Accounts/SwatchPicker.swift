import SwiftUI

/// A row of `AccountAppearance.palette` circles. The selected one shows a checkmark.
struct SwatchPicker: View {
    @Binding var selection: Int?
    var spacing: CGFloat = Tokens.Space.s1
    /// The clickable square around each circle.
    var targetSize: CGFloat = Tokens.Space.s6

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(AccountAppearance.palette.indices, id: \.self) { index in
                let swatch = AccountAppearance.palette[index]
                let isSelected = selection == index
                Button { selection = index } label: {
                    Circle().fill(swatch.color)
                        .frame(width: Tokens.Space.s5, height: Tokens.Space.s5)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: targetSize, height: targetSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(swatch.name).accessibilityLabel(swatch.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}
