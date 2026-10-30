import MessageContent
import SwiftUI

struct EmailCalendarSuggestionsView: View {
    @Bindable var model: EmailCalendarModel
    let onReview: (EmailCalendarItem) -> Void
    let onOpenExisting: (EmailCalendarItem) -> Void
    let onRespond: (EmailCalendarItem, InvitationReply.Answer) -> Void
    var onDismiss: (String) -> Void = { _ in }

    var body: some View {
        if !model.visibleItems.isEmpty || model.isInterpreting {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack {
                    Label("Events in this conversation", systemImage: "calendar")
                        .font(.headline)
                    Spacer()
                    if model.isInterpreting { ProgressView().controlSize(.small) }
                }
                ForEach(model.visibleItems) { item in
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title).font(.body.weight(.medium))
                            Spacer(minLength: Tokens.Space.s1)
                            Button {
                                model.dismiss(item.id)
                                onDismiss(item.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Dismiss this suggestion")
                            .accessibilityLabel("Dismiss \(item.title)")
                        }
                        if let start = item.event?.startDate {
                            Text(start.formatted(date: .abbreviated, time: item.event?.isAllDay == true ? .omitted : .shortened))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if !item.evidence.isEmpty {
                            Text(item.evidence).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                .textSelection(.enabled)
                        }
                        if item.isOutdated {
                            Text("A newer invitation appears in this conversation.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if item.kind == .cancelled {
                            Label("Cancelled in this conversation", systemImage: "calendar.badge.minus")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !item.uncertainties.isEmpty {
                            Text(item.uncertainties.joined(separator: " "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Tokens.Space.s2) { actions(item) }
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) { actions(item) }
                        }
                        .controlSize(.small)
                    }
                    .padding(Tokens.Space.s2)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                if let error = model.interpretationError {
                    Text("Calendar suggestions: \(error)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Tokens.Space.s3)
            .background(.background, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func actions(_ item: EmailCalendarItem) -> some View {
        if item.existingEventID != nil {
            Button("View Event") { onOpenExisting(item) }
            if item.canReview, item.kind == .updated || item.kind == .cancelled {
                Button(item.kind == .cancelled ? "Review Cancellation" : "Review Update") { onReview(item) }
            }
        } else if item.canReview {
            Button(item.invitation == nil ? "Review Event" : "Add Personal Copy") { onReview(item) }
        }
        if !item.isOutdated, item.kind != .cancelled,
           item.invitation?.method == .request,
           model.attendee(for: item) != nil {
            Menu(item.existingEventID == nil ? "Reply to Invitation" : "Respond") {
                Button("Accept") { onRespond(item, .accepted) }
                Button("Maybe") { onRespond(item, .tentative) }
                Button("Decline") { onRespond(item, .declined) }
            }
        }
    }
}
