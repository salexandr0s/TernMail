import MailStore
import SwiftUI

struct AttachmentLibraryFilters: View {
    @Bindable var model: AttachmentLibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack {
                Text("Filter attachments").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Form {
                    Section {
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
                        Text("Format is the file type. Categories describe what a document is for and can be changed from its menu.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Email date") {
                        dateFilter("From", date: $model.startDate)
                        dateFilter("Through", date: $model.endDate)
                        if let start = model.startDate, let end = model.endDate, start > end {
                            Label("The end date is before the start date.", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Section("File size") {
                        TextField("At least (MB)", text: sizeBinding($model.minimumSize), prompt: Text("Any"))
                        TextField("At most (MB)", text: sizeBinding($model.maximumSize), prompt: Text("Any"))
                        if let minimum = model.minimumSize, let maximum = model.maximumSize, minimum > maximum {
                            Label("The maximum is smaller than the minimum.", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Button("Clear all filters") { model.clearFilters() }
                .disabled(AttachmentFilterChip.values(for: model).isEmpty)
        }
        .padding(Tokens.Space.s4)
        .frame(width: Tokens.Sheet.smallWidth, height: Tokens.Layout.shortcutsHeight)
    }

    private func dateFilter(_ title: String, date: Binding<Date?>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { date.wrappedValue != nil }, set: { enabled in
                date.wrappedValue = enabled ? Calendar.current.startOfDay(for: .now) : nil
            }))
            if date.wrappedValue != nil {
                DatePicker(title, selection: Binding(get: { date.wrappedValue ?? .now }, set: {
                    date.wrappedValue = Calendar.current.startOfDay(for: $0)
                }), displayedComponents: .date)
                .labelsHidden()
            }
        }
    }

    private func sizeBinding(_ bytes: Binding<Int?>) -> Binding<String> {
        Binding(get: {
            guard let value = bytes.wrappedValue else { return "" }
            return (Double(value) / 1_000_000).formatted(.number.grouping(.never))
        }, set: { text in
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            guard let value = formatter.number(from: text)?.doubleValue, value.isFinite, value >= 0,
                  value < Double(Int.max) / 1_000_000 else {
                bytes.wrappedValue = nil
                return
            }
            bytes.wrappedValue = Int(value * 1_000_000)
        })
    }

    private func labelTitle(_ label: LabelRecord) -> String {
        guard model.availableAccounts.count > 1,
              let account = model.availableAccounts.first(where: { $0.id == label.accountID }) else { return label.name }
        return "\(label.name) · \(account.email)"
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
            let name = model.availableLabels.first { $0.accountID == label.accountID && $0.id == label.id }?.name ?? "Label"
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
            FlowLayout(spacing: Tokens.Space.s2) {
                ForEach(chips) { chip in
                    Button(action: chip.remove) {
                        HStack(spacing: Tokens.Space.s1) {
                            Text(chip.title).lineLimit(1)
                            Image(systemName: "xmark").imageScale(.small)
                        }
                        .font(.caption)
                        .padding(.horizontal, Tokens.Space.s2).padding(.vertical, Tokens.Space.s1)
                        .background(Tokens.Surface.muted, in: Capsule())
                        .overlay { Capsule().strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(chip.title)")
                    .accessibilityLabel("Remove filter: \(chip.title)")
                }
                Button("Clear all") { model.clearFilters() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}
