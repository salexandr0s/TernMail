import SwiftUI
import SyncEngine

struct MailOrganizationCategoryRow: View {
    @Binding var category: MailOrganizationReviewCategory
    let samples: MailOrganizationSamples
    let canCreateFilters: Bool
    var isEditable = true
    var isApplied = false
    var onOpenMessage: ((MailOrganizationSample) -> Void)? = nil
    @State private var isExpanded = false
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
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                if isEditable {
                    Toggle("Include \(displayName)", isOn: $category.isSelected)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .frame(width: Tokens.Control.icon, height: Tokens.Control.iconButton)
                        .accessibilityLabel("Include \(displayName)")
                        .accessibilityIdentifier("organization.category.\(category.id).selected")
                }
                disclosureButton
            }
            .padding(Tokens.Space.s4)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    exampleList
                    Divider()
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        Text(isEditable ? "Label settings" : "Label details")
                            .font(.subheadline.weight(.semibold))
                        if isEditable {
                            editingControls
                        } else {
                            readOnlyDetails
                        }
                    }
                }
                .padding(Tokens.Space.s4)
            }
        }
        .ternSurface()
        .ternAnimation(value: isExpanded)
        .accessibilityElement(children: .contain)
    }

    private var disclosureButton: some View {
        Button { isExpanded.toggle() } label: {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Image(systemName: "tag.fill")
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .background(tint.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                        Text(displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .help(displayName)
                        Spacer(minLength: 0)
                        TernBadge(text: "\(category.selectedMessageIDs.count)")
                            .accessibilityHidden(true)
                    }
                    Text(category.proposal.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Tokens.Space.s2) {
                        Text(labelState)
                        Text("·").accessibilityHidden(true)
                        Text(includesFutureMail ? "Future mail" : "Recent mail only")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, Tokens.Space.s1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Tokens.Space.s4, height: Tokens.Control.iconButton)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ternHover()
        .accessibilityLabel("\(displayName), \(category.selectedMessageIDs.count) messages selected, \(labelState), \(includesFutureMail ? "future mail filter" : "recent mail only")")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("\(category.proposal.explanation) \(isExpanded ? "Hide" : "Show") examples and label details.")
        .accessibilityIdentifier("organization.category.\(category.id).disclosure")
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
            if category.selectedMessageIDs != Set(category.proposal.messageIDs) {
                SettingsNote("Message choices changed. Future filters are turned off; you can enable a filter again only for senders whose examples are all included.")
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
