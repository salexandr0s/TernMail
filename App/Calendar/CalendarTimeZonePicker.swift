import SwiftUI

/// Chooses among every time zone the system knows. The button shows the
/// current zone; the popover filters the list as you type.
struct CalendarTimeZonePicker: View {
    let title: String
    @Binding var identifier: String
    @State private var isPresented = false
    @State private var query = ""
    @State private var highlighted: String?

    private static let identifiers = TimeZone.knownTimeZoneIdentifiers

    var body: some View {
        LabeledContent(title) {
            Button { isPresented.toggle() } label: {
                HStack(spacing: Tokens.Space.s1) {
                    Text(Self.displayName(identifier)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .help("Choose a time zone")
            .accessibilityLabel(title)
            .accessibilityValue(Self.displayName(identifier))
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            TextField("Search time zones", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(Tokens.Space.s2)
            Divider()
            List(filtered, id: \.self, selection: $highlighted) { zone in
                HStack {
                    Text(Self.displayName(zone)).lineLimit(1)
                    Spacer(minLength: Tokens.Space.s2)
                    Text(Self.offsetText(zone)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .tag(zone)
            }
            .listStyle(.plain)
            .frame(height: Tokens.Popover.maxListHeight)
            .overlay {
                if filtered.isEmpty {
                    Text("No matching time zones").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: Tokens.Popover.width)
        .onAppear { query = ""; highlighted = identifier }
        .onChange(of: highlighted) { _, zone in
            guard let zone, zone != identifier else { return }
            identifier = zone
            isPresented = false
        }
    }

    private var filtered: [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Self.identifiers }
        return Self.identifiers.filter { Self.matches($0, needle) }
    }

    /// "Europe/Vienna" reads as "Europe/Vienna"; underscores become spaces.
    static func displayName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    static func matches(_ identifier: String, _ needle: String) -> Bool {
        if displayName(identifier).lowercased().contains(needle) { return true }
        return TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: .current)?.lowercased().contains(needle) ?? false
    }

    static func offsetText(_ identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return "" }
        let seconds = zone.secondsFromGMT()
        let hours = abs(seconds) / 3600
        let minutes = (abs(seconds) % 3600) / 60
        return "GMT" + (seconds < 0 ? "-" : "+") + String(format: "%02d:%02d", hours, minutes)
    }
}
