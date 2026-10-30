import MailStore
import SwiftUI

struct MaintenanceSettingsView: View {
    let app: AppModel
    @AppStorage(CacheMaintenanceModel.budgetKey) private var budget = CacheMaintenanceModel.defaultBudgetMiB
    @State private var confirmsReset = false
    @State private var resetError: String?

    var body: some View {
        @Bindable var model = app.maintenance
        Form {
            Section("Mail cache") {
                LabeledContent("Total", value: bytes(model.totalBytes))
                LabeledContent("Database", value: bytes(model.usage.databaseBytes))
                LabeledContent("Downloaded attachments", value: bytes(model.usage.downloadedAttachmentBytes))
                Text("The database includes \(bytes(model.usage.bodyBytes)) of message bodies and \(bytes(model.usage.resourceBytes)) of inline images. Downloads copies are separate and stay where you saved them.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Cache budget", selection: $budget) {
                    ForEach(CacheMaintenanceModel.budgetChoices, id: \.self) { size in
                        Text(size >= 1024 ? "\(size / 1024) GiB" : "\(size) MiB").tag(size)
                    }
                }
                Text("Tern trims older bodies and managed attachment copies first. Open conversations, drafts, pending changes and pending alerts stay protected.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh Size") { Task { await model.refresh() } }
                    Button("Trim Now") { Task { await model.enforceBudget() } }
                        .disabled(model.readiness?.canReset != true)
                    if model.isRefreshing || model.isTrimming { ProgressView().controlSize(.small) }
                }
                .disabled(model.isTrimming || app.isResettingCache)
                if let status = model.status {
                    Label(status, systemImage: model.protectedBudgetLimit ? "lock.shield" : "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            Section("Reset cache") {
                Text("Rebuild downloaded mail from Gmail. Accounts, profiles, templates, signatures, saved searches and Calendar data stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                if let readiness = model.readiness, !readiness.canReset {
                    Text("Reset is unavailable: \(readiness.localDraftCount) local drafts, \(readiness.activeActionCount) pending changes and \(readiness.failedActionCount) failed changes. Send or discard drafts, and finish or discard changes first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Reset Mail Cache…", role: .destructive) { confirmsReset = true }
                    .disabled(model.readiness?.canReset != true || model.isTrimming || app.isResettingCache)
                if app.isResettingCache { ProgressView("Rebuilding mail…") }
                if let resetError { Text(resetError).font(.callout).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
        .onChange(of: budget) { _, _ in Task { await model.enforceBudget() } }
        .confirmationDialog("Reset downloaded mail?", isPresented: $confirmsReset) {
            Button("Reset Mail Cache", role: .destructive) {
                Task {
                    do { try await app.resetMailCache(); resetError = nil }
                    catch { resetError = "Couldn't reset the cache. Make sure all drafts and pending changes are finished." }
                    await model.refresh()
                }
            }
        } message: {
            Text("Tern downloads mail again after the reset. Your Google accounts and saved settings are kept.")
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
