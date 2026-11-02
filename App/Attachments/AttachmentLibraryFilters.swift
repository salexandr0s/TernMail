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
                Section("Source email") {
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
                Section("File") {
                    Picker("Category", selection: $model.category) {
                        Text("Any category").tag(nil as AttachmentCategory?)
                        ForEach(AttachmentCategory.allCases, id: \.self) { category in
                            Text(category.title).tag(category as AttachmentCategory?)
                        }
                    }
                    TextField("File format", text: $model.fileExtension, prompt: Text("Extension, such as pdf"))
                    Text("Categories are detected on this Mac. Correct a file's category from its actions menu.")
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
            .frame(minHeight: 0, maxHeight: .infinity)
            PopupFooter {
                Button("Clear Search & Filters") { model.clearFilters() }
                    .disabled(AttachmentFilterChip.values(for: model).isEmpty)
                    .help("Clear search, account, category and all other filters")
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: Tokens.Sheet.smallWidth)
        // Only the form scrolls; reset and Done remain reachable in short windows.
        .frame(minHeight: Tokens.Popover.maxListHeight, idealHeight: Tokens.Layout.windowMinHeight,
               maxHeight: Tokens.Layout.windowMinHeight)
        .accessibilityIdentifier("attachments.filters")
    }

    private func dateFilter(_ title: String, isOn: Binding<Bool>, day: Binding<Date>) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            if isOn.wrappedValue {
                DatePicker(title, selection: day, displayedComponents: .date)
                    .labelsHidden()
            }
        }
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
            chips.append(.init(id: "account", title: "Account: \(account)", remove: { model.accountID = "" }))
        }
        if !model.sender.isEmpty {
            chips.append(.init(id: "sender", title: "From: \(model.sender)", remove: { model.sender = "" }))
        }
        if !model.fileExtension.isEmpty {
            chips.append(.init(id: "format", title: "Format: \(model.fileExtension.uppercased())", remove: { model.fileExtension = "" }))
        }
        if let category = model.category {
            chips.append(.init(id: "category", title: "Category: \(category.title)", remove: { model.category = nil }))
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
        let chips = AttachmentFilterChip.values(for: model)
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                HStack(spacing: Tokens.Space.s2) {
                    Text("Active filters").font(.caption.weight(.semibold))
                    Spacer(minLength: Tokens.Space.s2)
                    Button("Clear Search & Filters") { model.clearFilters() }
                        .buttonStyle(.link).font(.caption)
                        .help("Clear search, account, category and all other filters")
                }
                .foregroundStyle(.secondary)
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
                        }
                    }
                    .padding(.vertical, Tokens.Space.s1)
                }
                .frame(height: Tokens.Space.s10)
                .accessibilityLabel("Active filters")
            }
        }
    }
}
