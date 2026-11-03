import SwiftUI

struct CalendarEditorSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CalendarEditorCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) { content }
            .padding(Tokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ternSurface(radius: Tokens.Radius.lg)
    }
}

/// Calendar IDs may belong to a shared calendar; account photos use the owner ID.
struct CalendarEditorAccountAvatar: View {
    let calendar: CalendarDisplayCalendar
    var size: CGFloat = Tokens.Control.avatar

    var body: some View {
        Group {
            if let image = AccountProfileImages.shared.image(for: calendar.accountID) {
                AvatarImage(image: image, size: size)
            } else {
                TernAvatar(name: calendar.accountName, size: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(calendar.color)
                .frame(width: Tokens.Space.s2, height: Tokens.Space.s2)
                .overlay { Circle().strokeBorder(Tokens.Surface.primary, lineWidth: Tokens.Border.hairline) }
        }
        .accessibilityHidden(true)
    }
}

struct CalendarEditorCalendarPicker: View {
    @Binding var selection: String
    let calendars: [CalendarDisplayCalendar]
    @State private var isPresented = false

    private var selected: CalendarDisplayCalendar? { calendars.first { $0.id == selection } }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: Tokens.Space.s2) {
                if let selected { CalendarEditorAccountAvatar(calendar: selected, size: Tokens.Space.s6) }
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(selected?.title ?? "Choose a calendar")
                        .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(Tokens.Space.s2)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: Tokens.Settings.pickerWidth, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
        .ternSurface(radius: Tokens.Radius.md)
        .ternHover()
        .accessibilityLabel("Calendar")
        .accessibilityValue(selected.map { "\($0.title), \($0.accountName)" } ?? "Choose a calendar")
        .help(selected.map { "\($0.title) · \($0.accountName)" } ?? "Choose a calendar")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("Choose a calendar").font(.headline).padding(Tokens.Space.s2)
                ScrollView {
                    VStack(spacing: Tokens.Space.s1) {
                        ForEach(calendars.filter { $0.canWrite || $0.id == selection }) { item in
                            Button {
                                selection = item.id
                                isPresented = false
                            } label: {
                                HStack(spacing: Tokens.Space.s3) {
                                    CalendarEditorAccountAvatar(calendar: item)
                                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                        Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                                        Text(item.accountName).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: Tokens.Space.s2)
                                    if item.id == selection {
                                        Image(systemName: "checkmark").font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(Tokens.Space.s2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(item.id == selection ? Color.accentColor.opacity(Tokens.Opacity.wash) : .clear,
                                            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
                            }
                            .buttonStyle(.plain).ternHover()
                            .accessibilityLabel("\(item.title), \(item.accountName)")
                            .accessibilityAddTraits(item.id == selection ? .isSelected : [])
                            .help("\(item.title) · \(item.accountName)")
                        }
                    }
                }
                .frame(maxHeight: Tokens.Popover.maxListHeight)
            }
            .padding(Tokens.Space.s2)
            .frame(width: Tokens.Popover.width)
        }
    }
}
