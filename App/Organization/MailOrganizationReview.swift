import SwiftUI
import SyncEngine

/// Review content is independent of account connections and can render a
/// prepared plan without reading mail or starting an assistant request.
struct MailOrganizationReviewSections: View {
    @Bindable var model: MailOrganizationModel
    let canCreateFilters: Bool
    var onOpenMessage: ((MailOrganizationSample) -> Void)? = nil
    @State private var focusedCategoryID = ""
    @State private var usesColumns = false

    private var isReviewing: Bool { model.phase == .review }
    private var allSelected: Bool { model.selectedCount == model.categories.count }
    private var visibleCategories: [MailOrganizationReviewCategory] {
        model.categories.filter { isReviewing || $0.isSelected }
    }
    private var title: String {
        switch model.phase {
        case .review: "Review your labels"
        case .complete: "Applied labels"
        default: "Selected labels"
        }
    }

    var body: some View {
        if let samples = model.samples {
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
                        Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        if isReviewing && !model.categories.isEmpty {
                            Button(allSelected ? "Deselect all" : "Select all", action: toggleAll)
                                .buttonStyle(.borderless).font(.callout)
                                .accessibilityIdentifier("organization.selectAll")
                        }
                    }
                    Text("\(samples.messages.count) analyzed · \(samples.messages.filter { !$0.isSent }.count) received · \(samples.messages.filter(\.isSent).count) sent")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isReviewing {
                        Text("Choose a label, then check its name, messages, and future mail settings.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if samples.isPartial {
                    SettingsNote("Some messages were unavailable. You can label this sample; future filters need a complete sample.",
                                 systemImage: "exclamationmark.triangle")
                }
                if visibleCategories.isEmpty {
                    TernEmptyState(title: "No labels suggested", systemImage: "tag",
                        message: "These messages didn't suggest consistent categories. Try again as new mail arrives.",
                        fillsSpace: false)
                        .ternSurface()
                } else {
                    let layout = usesColumns
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: Tokens.Space.s5))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Space.s4))
                    layout {
                        categoryNavigation
                            .frame(width: usesColumns ? Tokens.Settings.sidebarWidth : nil)
                        ForEach($model.categories) { $category in
                            if category.id == focusedCategoryID {
                                MailOrganizationCategoryRow(category: $category, samples: samples,
                                    canCreateFilters: canCreateFilters && !samples.isPartial,
                                    isEditable: isReviewing, isApplied: model.phase == .complete,
                                    onOpenMessage: onOpenMessage)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { $0.size.width >= Tokens.Settings.contentWidth } action: {
                usesColumns = $0
            }
            .onChange(of: visibleCategories.map(\.id), initial: true) { _, ids in
                if !ids.contains(focusedCategoryID) { focusedCategoryID = ids.first ?? "" }
            }
        }
    }

    @ViewBuilder private var categoryNavigation: some View {
        if usesColumns {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("\(visibleCategories.count) labels")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.Space.s3)
                ForEach(visibleCategories) { category in
                    Button { focusedCategoryID = category.id } label: {
                        HStack(alignment: .top, spacing: Tokens.Space.s2) {
                            Image(systemName: category.isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(category.isSelected ? Color.accentColor : Color.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(category.name.isEmpty ? "Untitled label" : category.name)
                                    .font(.callout.weight(.medium)).foregroundStyle(.primary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Text("\(category.selectedMessageIDs.count) messages")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Tokens.Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(focusedCategoryID == category.id ? Color.accentColor.opacity(Tokens.Opacity.tint) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    }
                    .buttonStyle(.plain).ternHover()
                    .help(category.name)
                    .accessibilityLabel("\(category.name), \(category.selectedMessageIDs.count) messages, \(category.isSelected ? "included" : "excluded")")
                    .accessibilityAddTraits(focusedCategoryID == category.id ? .isSelected : [])
                    .accessibilityIdentifier("organization.category.\(category.id).review")
                }
            }
        } else {
            Picker("Label to review", selection: $focusedCategoryID) {
                ForEach(visibleCategories) { category in
                    Text("\(category.name.isEmpty ? "Untitled label" : category.name) · \(category.selectedMessageIDs.count) messages")
                        .tag(category.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("organization.categoryPicker")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleAll() {
        let selected = !allSelected
        for index in model.categories.indices { model.categories[index].isSelected = selected }
    }
}

struct MailOrganizationReviewFooter: View {
    @Bindable var model: MailOrganizationModel

    var body: some View {
        SettingsFooter {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                if model.selectedCount > 0, let message = model.validationMessage {
                    SettingsNote(message, systemImage: "exclamationmark.circle")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Space.s4) {
                        summary
                        Spacer(minLength: Tokens.Space.s3)
                        actions.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        summary
                        HStack { Spacer(minLength: 0); actions }
                    }
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(model.selectedCount == 0 ? "Choose labels to apply" : model.canApply ? "Ready to apply" : "Review your selection")
                .font(.callout.weight(.semibold))
            Text("\(model.selectedCount) \(model.selectedCount == 1 ? "label" : "labels") · \(messageSummary)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: Tokens.Space.s3) {
            Button("Start over", action: model.clear)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("organization.startOver")
            Button("Apply to Gmail", action: model.applySelection)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.canApply)
                .accessibilityIdentifier("organization.apply")
        }
    }

    private var messageSummary: String {
        let messages = "\(model.selectedMessageCount) \(model.selectedMessageCount == 1 ? "message" : "messages")"
        guard model.selectedFilterCount > 0 else { return messages }
        return messages + " · \(model.selectedFilterCount) future \(model.selectedFilterCount == 1 ? "filter" : "filters")"
    }
}
