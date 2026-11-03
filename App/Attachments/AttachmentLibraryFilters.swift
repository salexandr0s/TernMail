import MailStore
import SwiftUI

struct AttachmentLibraryFilters: View {
    @Bindable var model: AttachmentLibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopupHeader(title: "Filter Attachments", systemImage: "line.3.horizontal.decrease",
                subtitle: "Results update as you choose.")
            Form {
                Section("Email") {
                    Picker("Account", selection: $model.accountID) {
                        Text("All accounts").tag("")
                        ForEach(model.availableAccounts) { account in
                            Text(account.email).tag(account.id)
                        }
                    }
                    TextField("Sender", text: $model.sender, prompt: Text("Name or email address"))
                    Picker("Email label", selection: $model.label) {
                        Text("Any label").tag(nil as AttachmentLibraryLabel?)
                        ForEach(model.availableLabels, id: \.libraryIdentity) { label in
                            Text(labelTitle(label))
                                .tag(AttachmentLibraryLabel(accountID: label.accountID, id: label.id) as AttachmentLibraryLabel?)
                        }
                    }
                }
                Section("Document") {
                    TextField("File format", text: $model.fileExtension, prompt: Text("Extension, such as pdf"))
                    Picker("Category", selection: $model.category) {
                        Text("Any category").tag(nil as AttachmentCategory?)
                        ForEach(AttachmentCategory.allCases, id: \.self) { category in
                            Text(category.title).tag(category as AttachmentCategory?)
                        }
                    }
                    Text("Categories are detected automatically on this Mac. You can correct them from an attachment's menu. File format uses the extension, such as pdf or docx.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Email date") {
                    dateFilter("From", isOn: $model.hasStartDate, day: $model.startDay)
                    dateFilter("Through", isOn: $model.hasEndDate, day: $model.endDay)
                    if let start = model.startDate, let end = model.endDate, start > end {
                        Label("The end date is before the start date.", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(Tokens.Status.warning)
                    }
                }
                Section("File size") {
                    TextField("At least (MB)", value: $model.minimumMegabytes, format: .number.grouping(.never), prompt: Text("Any"))
                    TextField("At most (MB)", value: $model.maximumMegabytes, format: .number.grouping(.never), prompt: Text("Any"))
                    if let minimum = model.minimumSize, let maximum = model.maximumSize, minimum > maximum {
                        Label("The maximum is smaller than the minimum.", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(Tokens.Status.warning)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            PopupFooter {
                Button("Clear All Filters") { model.clearFilters() }
                    .disabled(AttachmentFilterChip.values(for: model).isEmpty)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: Tokens.Sheet.smallWidth)
        // As tall as the filters it holds, so nothing scrolls inside the popover.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func dateFilter(_ title: String, isOn: Binding<Bool>, day: Binding<Date>) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            if isOn.wrappedValue {
                DatePicker(title, selection: day, displayedComponents: .date)
                    .labelsHidden()
                    .ternTransition(.fade)
            }
        }
        .ternAnimation(value: isOn.wrappedValue)
    }

    private func labelTitle(_ label: LabelRecord) -> String {
        guard model.availableAccounts.count > 1,
              let account = model.availableAccounts.first(where: { $0.id == label.accountID }) else { return label.title }
        return "\(label.title) · \(account.email)"
    }
}

private extension LabelRecord {
    var libraryIdentity: String { "\(accountID.count):\(accountID)\(id)" }
}

struct AttachmentFilterChip: Identifiable {
    let id: String
    let title: String
    let remove: @MainActor () -> Void

    @MainActor static func values(for model: AttachmentLibraryModel) -> [AttachmentFilterChip] {
        var chips: [AttachmentFilterChip] = []
        if !model.search.isEmpty {
            chips.append(.init(id: "search", title: "Search: \(model.search)", remove: { model.search = "" }))
        }
        if !model.accountID.isEmpty {
            let account = model.availableAccounts.first { $0.id == model.accountID }?.email ?? "Account"
            chips.append(.init(id: "account", title: account, remove: { model.accountID = "" }))
        }
        if !model.sender.isEmpty {
            chips.append(.init(id: "sender", title: "From: \(model.sender)", remove: { model.sender = "" }))
        }
        if !model.fileExtension.isEmpty {
            chips.append(.init(id: "format", title: "Format: \(model.fileExtension.uppercased())", remove: { model.fileExtension = "" }))
        }
        if let category = model.category {
            chips.append(.init(id: "category", title: category.title, remove: { model.category = nil }))
        }
        if let start = model.startDate {
            chips.append(.init(id: "start", title: "From \(start.formatted(date: .abbreviated, time: .omitted))", remove: { model.startDate = nil }))
        }
        if let end = model.endDate {
            chips.append(.init(id: "end", title: "Through \(end.formatted(date: .abbreviated, time: .omitted))", remove: { model.endDate = nil }))
        }
        if let minimum = model.minimumSize {
            chips.append(.init(id: "minimum", title: "At least \(AttachmentPresentation.size(minimum))", remove: { model.minimumSize = nil }))
        }
        if let maximum = model.maximumSize {
            chips.append(.init(id: "maximum", title: "At most \(AttachmentPresentation.size(maximum))", remove: { model.maximumSize = nil }))
        }
        if let label = model.label {
            let name = model.availableLabels.first { $0.accountID == label.accountID && $0.id == label.id }?.title ?? "Label"
            chips.append(.init(id: "label", title: "Label: \(name)", remove: { model.label = nil }))
        }
        return chips
    }
}

struct AttachmentActiveFilters: View {
    let model: AttachmentLibraryModel

    var body: some View {
        // Search and category already have visible, editable controls above.
        let chips = AttachmentFilterChip.values(for: model).filter { $0.id != "search" && $0.id != "category" }
        if !chips.isEmpty {
            HStack(spacing: Tokens.Space.s3) {
                ScrollView(.horizontal) {
                    HStack(spacing: Tokens.Space.s2) {
                        ForEach(chips) { chip in
                            Button(action: chip.remove) {
                                HStack(spacing: Tokens.Space.s1) {
                                    Text(chip.title).lineLimit(1).truncationMode(.middle)
                                    Image(systemName: "xmark").imageScale(.small)
                                }
                                .font(.caption)
                                .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s1_5)
                                .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: Capsule())
                                .overlay { Capsule().strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
                                .frame(maxWidth: Tokens.Layout.attachmentWidth)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(chip.title)")
                            .accessibilityLabel("Remove filter: \(chip.title)")
                            .ternTransition(.fade)
                        }
                    }
                    .padding(.vertical, Tokens.Space.s1)
                }
                .frame(height: Tokens.Space.s12)
                .accessibilityLabel("Active filters")
                Button("Clear all") { model.clearFilters() }
                    .buttonStyle(.link).font(.caption).fixedSize()
            }
            .ternTransition(.disclosure)
        }
    }
}

/// These shortcuts filter detected and corrected categories, using the same state as the popover.
struct AttachmentCategoryShortcuts: View {
    @Bindable var model: AttachmentLibraryModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s1) {
                categoryButton(nil)
                ForEach(AttachmentCategory.allCases, id: \.self) { category in categoryButton(category) }
            }
            .fixedSize()
            Picker("Category", selection: $model.category) {
                Text("All categories").tag(nil as AttachmentCategory?)
                ForEach(AttachmentCategory.allCases, id: \.self) { category in
                    Text(category.title).tag(category as AttachmentCategory?)
                }
            }
            .frame(maxWidth: Tokens.Popover.width, alignment: .leading)
        }
        .help("Filter automatically detected categories and your corrections")
    }

    private func categoryButton(_ category: AttachmentCategory?) -> some View {
        let selected = model.category == category
        return Button { model.category = category } label: {
            Text(category?.title ?? "All categories")
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
                .background(selected ? Color.accentColor.opacity(Tokens.Opacity.tint) : .clear,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(selected ? (contrast == .increased ? Color.primary : Color.accentColor.opacity(Tokens.Opacity.outline)) : .clear,
                                      lineWidth: Tokens.Border.hairline)
                        .allowsHitTesting(false)
                }
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category?.title ?? "All categories")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
