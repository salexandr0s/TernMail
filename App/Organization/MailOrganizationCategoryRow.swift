import SwiftUI
import SyncEngine

struct MailOrganizationCategoryRow: View {
    @Binding var category: MailOrganizationReviewCategory
    let samples: MailOrganizationSamples
    let canCreateFilters: Bool
    var isEditable = true
    var isApplied = false
    var onOpenMessage: ((MailOrganizationSample) -> Void)? = nil
    @State private var visibleExampleCount = 4

    private var examples: [MailOrganizationSample] {
        let ids = Set(category.proposal.messageIDs)
        return samples.messages.filter { ids.contains($0.messageID) }
    }

    private var reusesLabel: Bool {
        let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return samples.existingLabels.contains { !$0.isSystem && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private var displayName: String {
        let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled label" : name
    }

    private var tint: Color {
        switch category.proposal.kind {
        case .topic: .accentColor
        case .action: .orange
        case .waiting: .purple
        }
    }

    private var hasRecurringSenders: Bool {
        category.proposal.kind == .topic && !eligibleRuleSenders.isEmpty
    }

    private var eligibleRuleSenders: [String] {
        samples.eligibleRuleSenders(category.proposal.ruleSenders, selectedMessageIDs: category.selectedMessageIDs)
    }

    private var labelState: String {
        if isApplied { return "Saved in Gmail" }
        if !isEditable { return "Selected label" }
        return reusesLabel ? "Existing label" : "New label"
    }

    private var includesFutureMail: Bool {
        category.createsFilter && hasRecurringSenders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                HStack(alignment: .top, spacing: Tokens.Space.s3) {
                    Image(systemName: "tag.fill")
                        .font(.title2).foregroundStyle(tint)
                        .frame(width: Tokens.Space.s10, height: Tokens.Space.s10)
                        .background(tint.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(displayName).font(.title3.bold()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(labelState).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(category.proposal.explanation)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isEditable {
                    Toggle("Include this label", isOn: $category.isSelected)
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Include \(displayName)")
                        .accessibilityIdentifier("organization.category.\(category.id).selected")
                }
            }
            .padding(Tokens.Space.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(Tokens.Opacity.wash),
                        in: UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.lg,
                                                   topTrailingRadius: Tokens.Radius.lg))
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                if isEditable { editingControls } else { readOnlyDetails }
                Divider()
                exampleList
            }
            .padding(Tokens.Space.s5)
        }
        .ternSurface()
        .accessibilityElement(children: .contain)
    }

    private var editingControls: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Label name").font(.caption).foregroundStyle(.secondary)
                TextField("Label name", text: $category.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Gmail label name for \(displayName)")
                    .disabled(!isEditable || !category.isSelected)
            }

            if hasRecurringSenders {
                Toggle("Also label future mail", isOn: $category.createsFilter)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!isEditable || !category.isSelected || !canCreateFilters)
                Text(eligibleRuleSenders.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsNote("The filter matches all incoming mail from these addresses.")
                if !canCreateFilters && !samples.isPartial && isEditable {
                    SettingsNote("Enable Gmail Settings in Connections to create future filters.", systemImage: "lock")
                }
            } else if category.proposal.kind != .topic {
                SettingsNote("These labels do not clear automatically when a reply arrives.")
            } else {
                SettingsNote("This label applies to the reviewed messages. A future rule needs recurring mail from a consistent mailing-list or automated sender.")
            }
            if category.proposal.kind == .topic, category.selectedMessageIDs != Set(category.proposal.messageIDs) {
                SettingsNote(category.createsFilter
                    ? "Future filters include only senders whose examples are all selected."
                    : "Message choices changed. Future filters are turned off; you can enable a filter again only for senders whose examples are all included.")
            }
        }
    }

    private var readOnlyDetails: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Label name").font(.caption).foregroundStyle(.secondary)
                Text(displayName).font(.callout).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(isApplied ? "Label scope" : "Selected scope")
                    .font(.caption).foregroundStyle(.secondary)
                Text(includesFutureMail ? "Recent messages and future incoming mail" : "Recent messages only")
                    .font(.callout)
                if includesFutureMail {
                    Text("Incoming mail from \(eligibleRuleSenders.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if category.proposal.kind != .topic {
                SettingsNote("These labels do not clear automatically when a reply arrives.")
            }
        }
    }

    private var exampleList: some View {
        let available = isEditable ? examples : examples.filter { category.selectedMessageIDs.contains($0.messageID) }
        let shown = Array(available.prefix(visibleExampleCount))
        return VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(isEditable ? "Messages to label" : "Included messages").font(.subheadline.weight(.semibold))
                Spacer(minLength: Tokens.Space.s2)
                Text("\(shown.count) of \(available.count)").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(shown, id: \.messageID) { message in
                    HStack(alignment: .top, spacing: Tokens.Space.s2) {
                        if isEditable {
                            Toggle("Include \(message.subject)", isOn: $category.selectedMessageIDs.contains(message.messageID))
                                .toggleStyle(.checkbox).labelsHidden()
                                .disabled(!category.isSelected)
                        }
                        MailOrganizationExampleRow(message: message,
                            onOpen: onOpenMessage.map { open in { open(message) } })
                    }
                    .padding(Tokens.Space.s3)
                    if message.messageID != shown.last?.messageID {
                        Divider().padding(.horizontal, Tokens.Space.s3)
                    }
                }
            }
            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .ternOutline(radius: Tokens.Radius.md, style: .contrastOnly)
            if available.count > 4 {
                HStack(spacing: Tokens.Space.s3) {
                    if shown.count < available.count {
                        Button("Show \(min(4, available.count - shown.count)) More") { visibleExampleCount += 4 }
                            .accessibilityIdentifier("organization.category.\(category.id).showMore")
                    }
                    if visibleExampleCount > 4 {
                        Button("Show Less") { visibleExampleCount = 4 }
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
    }
}
