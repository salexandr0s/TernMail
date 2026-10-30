import MessageContent
import SwiftUI

/// A compact part of the conversation header. Details stay with their event so
/// a conversation summary can follow this group without repeating its content.
struct EmailCalendarSuggestionsView: View {
    @Bindable var model: EmailCalendarModel
    var calendar: Calendar = .autoupdatingCurrent
    let onReview: (EmailCalendarItem) -> Void
    let onOpenExisting: (EmailCalendarItem) -> Void
    let onRespond: (EmailCalendarItem, InvitationReply.Answer) -> Void
    var onDismiss: (String) -> Void = { _ in }
    @State private var showsAll = false

    private var orderedItems: [EmailCalendarItem] {
        EmailCalendarPresentation.ordered(model.visibleItems, messages: model.messages)
    }

    var body: some View {
        if !orderedItems.isEmpty || model.isInterpreting || model.interpretationError != nil {
            VStack(alignment: .leading, spacing: 0) {
                header
                let displayed = showsAll ? orderedItems : Array(orderedItems.prefix(2))
                ForEach(displayed) { item in
                    if item.id != displayed.first?.id {
                        Divider().padding(.horizontal, Tokens.Space.s3)
                    }
                    EmailCalendarSuggestionRow(
                        item: item, calendar: calendar,
                        canRespond: !item.isOutdated && item.kind != .cancelled
                            && item.invitation?.method == .request && model.attendee(for: item) != nil,
                        onReview: { onReview(item) }, onOpenExisting: { onOpenExisting(item) },
                        onRespond: { onRespond(item, $0) }, onDismiss: {
                            model.dismiss(item.id)
                            onDismiss(item.id)
                        })
                }
                if orderedItems.count > 2 {
                    Divider().padding(.horizontal, Tokens.Space.s3)
                    Button {
                        showsAll.toggle()
                    } label: {
                        HStack(spacing: Tokens.Space.s1) {
                            Text(showsAll ? "Show fewer" : "Show all \(orderedItems.count) events")
                            Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                            Spacer(minLength: 0)
                            if !showsAll, hiddenChanges > 0 {
                                Text(hiddenChanges == 1 ? "1 more update" : "\(hiddenChanges) more updates")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .padding(Tokens.Space.s3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsAll ? "Expanded" : "Collapsed")
                }
                if let error = model.interpretationError {
                    Text("Some events could not be checked. \(error)")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding([.horizontal, .bottom], Tokens.Space.s3)
                }
            }
            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline)
            }
            .accessibilityElement(children: .contain)
            .onChange(of: model.messages.map(\.id)) { _, _ in showsAll = false }
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s2) {
            Text("From this conversation")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: Tokens.Space.s1)
            if model.isInterpreting {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Checking events")
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.top, Tokens.Space.s3)
        .padding(.bottom, Tokens.Space.s1)
    }

    private var hiddenChanges: Int {
        orderedItems.dropFirst(2).filter { !$0.isOutdated && ($0.kind == .cancelled || $0.kind == .updated || $0.hasAmbiguousMatch) }.count
    }
}

private struct EmailCalendarSuggestionRow: View {
    let item: EmailCalendarItem
    let calendar: Calendar
    let canRespond: Bool
    let onReview: () -> Void
    let onOpenExisting: () -> Void
    let onRespond: (InvitationReply.Answer) -> Void
    let onDismiss: () -> Void
    @State private var showsDetails = false

    private var presentation: EmailCalendarPresentation { .init(item: item, calendar: calendar) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Tokens.Space.s3) {
                    dateTile
                    summary.frame(minWidth: Tokens.Space.s16 * 3)
                    VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                        primaryAction
                        moreMenu
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                HStack(alignment: .top, spacing: Tokens.Space.s3) {
                    dateTile
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        summary
                        HStack(spacing: Tokens.Space.s2) {
                            primaryAction
                            Spacer(minLength: 0)
                            moreMenu
                        }
                        .controlSize(.small)
                    }
                }
            }
            if showsDetails { details }
        }
        .padding(Tokens.Space.s3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(presentation.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
                .help(presentation.title)
                .textSelection(.enabled)
            Text(presentation.dateLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = presentation.status {
                Label(status.text, systemImage: status.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = item.authenticityWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateTile: some View {
        VStack(spacing: 0) {
            if let month = presentation.month, let day = presentation.day {
                Text(month)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.isOutdated || item.kind == .cancelled ? Color.secondary : .accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.Space.s1)
                    .background(Color.accentColor.opacity(Tokens.Calendar.eventTint))
                Text(day)
                    .font(.title2.weight(.medium).monospacedDigit())
                    .foregroundStyle(item.isOutdated ? .secondary : .primary)
                    .padding(.vertical, Tokens.Space.s1)
            } else {
                Image(systemName: "calendar.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(height: Tokens.Space.s12)
            }
        }
        .frame(width: Tokens.Space.s12)
        .background(Tokens.Surface.muted)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var primaryAction: some View {
        if item.canReview && (item.kind == .updated || item.kind == .cancelled) {
            reviewButton
        } else if canRespond {
            Menu("Respond") { responseActions }
                .menuStyle(.borderedButton)
                .help("Reply to this invitation")
        } else if item.existingEventID != nil {
            Button("Open", action: onOpenExisting)
                .help("Open this event in Calendar")
        } else if item.canReview {
            reviewButton
        }
    }

    private var reviewButton: some View {
        Button("Review", action: onReview)
            .help(reviewTitle)
            .accessibilityLabel("\(reviewTitle): \(presentation.title)")
    }

    private var reviewTitle: String {
        if item.kind == .cancelled { return "Review Cancellation" }
        if item.kind == .updated, item.existingEventID != nil { return "Review Update" }
        return item.invitation == nil ? "Review Event" : "Add Personal Copy"
    }

    private var moreMenu: some View {
        Menu {
            Button(showsDetails ? "Hide Details" : "Show Details") { showsDetails.toggle() }
            if item.existingEventID != nil { Button("Open in Calendar", action: onOpenExisting) }
            if item.canReview, item.existingEventID == nil || item.kind == .updated || item.kind == .cancelled {
                Button(reviewTitle, action: onReview)
            }
            if canRespond { Menu("Reply to Invitation") { responseActions } }
            Divider()
            Button("Dismiss Suggestion", action: onDismiss)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Event details and actions")
        .accessibilityLabel("Details and actions for \(presentation.title)")
    }

    @ViewBuilder private var responseActions: some View {
        Button("Accept") { onRespond(.accepted) }
        Button("Maybe") { onRespond(.tentative) }
        Button("Decline") { onRespond(.declined) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Divider()
            if let location = presentation.location {
                Label(location, systemImage: "mappin.and.ellipse")
                    .textSelection(.enabled)
            }
            if let organizer = presentation.organizer {
                Label("Organizer: \(organizer)", systemImage: "person")
                    .textSelection(.enabled)
            }
            if let original = presentation.originalTimeZoneLine {
                Label(original, systemImage: "globe")
            }
            if let recurrence = presentation.recurrenceNote {
                Label(recurrence, systemImage: "repeat")
            }
            if let answer = presentation.answerLine {
                Label(answer, systemImage: "person.crop.circle.badge.checkmark")
            }
            ForEach(Array(presentation.responseLines.enumerated()), id: \.offset) { _, answer in
                Text(answer).textSelection(.enabled)
            }
            if let organizer = item.invitation?.organizer?.email, canRespond {
                Text("Invitation responses go to \(organizer).")
                    .textSelection(.enabled)
            }
            if item.invitation == nil, !item.evidence.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("In the email").font(.caption.weight(.medium))
                    Text(item.evidence).textSelection(.enabled)
                }
            }
            if item.isOutdated {
                Text("A newer invitation or cancellation is saved in this account.")
            }
            ForEach(Array(item.uncertainties.enumerated()), id: \.offset) { _, uncertainty in
                Label(uncertainty, systemImage: "info.circle")
            }
            Button("Hide Details") { showsDetails = false }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
