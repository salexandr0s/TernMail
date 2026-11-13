import SwiftUI

struct TodayCompactState: View {
    let title: String
    let symbol: String
    var message: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                .frame(width: Tokens.Space.s6).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.callout.weight(.medium))
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Tokens.Space.s2)
        .accessibilityElement(children: .combine)
    }
}

/// What a section's content shows: the state it is in and its rows. A section
/// animates its own content when this changes, and nothing outside it.
struct TodayContentKey: Equatable {
    var states: [Bool] = []
    var ids: [String] = []
}

struct TodayLoadingStatus: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TodayInlineWarning: View {
    let message: String
    let retry: (() -> Void)?
    init(_ message: String, retry: (() -> Void)? = nil) { self.message = message; self.retry = retry }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Tokens.Status.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry { Button("Retry", action: retry).buttonStyle(.link).controlSize(.small) }
        }
        .padding(Tokens.Space.s2)
        .background(Tokens.Status.warning.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .ternOutline(radius: Tokens.Radius.sm, style: .contrastOnly)
        .accessibilityElement(children: .contain)
    }
}

struct TodayCoverageNote: View {
    let summary: String
    let details: String
    var label = "Data coverage"
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1_5) {
            Text(summary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { showsDetails = true } label: {
                Image(systemName: "info.circle").font(.caption)
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).ternHover()
            .accessibilityLabel(label).accessibilityHint("Show which data is included.")
            .help(details)
            .popover(isPresented: $showsDetails) {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text(label).font(.headline)
                    Text(details).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Tokens.Space.s4).frame(width: Tokens.Popover.width)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
