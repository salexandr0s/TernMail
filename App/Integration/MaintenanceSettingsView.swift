import MailStore
import SwiftUI

struct MaintenanceSettingsView: View {
    let app: AppModel
    @AppStorage(CacheMaintenanceModel.budgetKey) private var budget = CacheMaintenanceModel.defaultBudgetMiB
    @State private var confirmsReset = false
    @State private var resetError: String?

    var body: some View {
        SettingsPage {
            usageSummary
            SettingsGroup("Cache management", systemImage: "externaldrive") {
                SettingsControlRow("Cache budget", detail: "Older mail and managed attachment copies are trimmed first.") {
                    Picker("Cache budget", selection: $budget) {
                        ForEach(CacheMaintenanceModel.budgetChoices, id: \.self) { size in
                            Text(size >= 1024 ? "\(size / 1024) GiB" : "\(size) MiB").tag(size)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().padding(.horizontal, Tokens.Space.s4)
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    SettingsNote("Open conversations, drafts, pending changes and pending alerts stay protected.", systemImage: "lock.shield")
                    HStack(spacing: Tokens.Space.s3) {
                        Button("Refresh Size", systemImage: "arrow.clockwise") { Task { await app.maintenance.refresh() } }
                            .disabled(app.maintenance.isRefreshing)
                        Spacer(minLength: 0)
                        if app.maintenance.isRefreshing || app.maintenance.isTrimming {
                            ProgressView().controlSize(.small)
                        }
                        Button("Trim Now") { Task { await app.maintenance.enforceBudget() } }
                            .disabled(app.maintenance.readiness?.canReset != true)
                    }
                    .disabled(app.maintenance.isTrimming || app.isResettingCache)
                    if let status = app.maintenance.status {
                        SettingsNote(status, systemImage: app.maintenance.protectedBudgetLimit ? "lock.shield" : "checkmark.circle")
                    }
                    if let error = app.maintenance.error { errorMessage(error) }
                }
                .padding(Tokens.Space.s3)
            }
            SettingsGroup("Reset downloaded mail", systemImage: "arrow.counterclockwise") {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text("Rebuild downloaded mail from Gmail. Accounts, profiles, templates, signatures, saved searches and Calendar data stay on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let readiness = app.maintenance.readiness, !readiness.canReset {
                        SettingsNote("Reset is unavailable: \(readiness.localDraftCount) local drafts, \(readiness.activeActionCount) pending changes and \(readiness.failedActionCount) failed changes. Send or discard drafts, and finish or discard changes first.", systemImage: "exclamationmark.circle")
                    }
                    HStack {
                        if app.isResettingCache { ProgressView("Rebuilding mail…").controlSize(.small) }
                        Spacer(minLength: 0)
                        Button("Reset Mail Cache…", role: .destructive) { confirmsReset = true }
                            .disabled(app.maintenance.readiness?.canReset != true || app.maintenance.isTrimming || app.isResettingCache)
                    }
                    if let resetError { errorMessage(resetError) }
                }
                .padding(Tokens.Space.s3)
            }
        }
        .task { await app.maintenance.refresh() }
        .onChange(of: budget) { _, _ in Task { await app.maintenance.enforceBudget() } }
        .confirmationDialog("Reset downloaded mail?", isPresented: $confirmsReset) {
            Button("Reset Mail Cache", role: .destructive) {
                Task {
                    do { try await app.resetMailCache(); resetError = nil }
                    catch { resetError = "Couldn't reset the cache. Make sure all drafts and pending changes are finished." }
                    await app.maintenance.refresh()
                }
            }
        } message: {
            Text("Tern downloads mail again after the reset. Your Google accounts and saved settings are kept.")
        }
    }

    private var usageSummary: some View {
        SettingsGroup("On this Mac", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Used").font(.body)
                    Spacer(minLength: Tokens.Space.s3)
                    Text("\(bytes(app.maintenance.totalBytes)) of \(bytes(budgetBytes))")
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                }
                ProgressView(value: Double(min(app.maintenance.totalBytes, budgetBytes)), total: Double(budgetBytes))
                    .tint(app.maintenance.totalBytes > budgetBytes ? .orange : .accentColor)
                    .accessibilityLabel("Mail cache usage")
                    .accessibilityValue("\(bytes(app.maintenance.totalBytes)) of \(bytes(budgetBytes))")
                LabeledContent("Database", value: bytes(app.maintenance.usage.databaseBytes))
                LabeledContent("Downloaded attachments", value: bytes(app.maintenance.usage.downloadedAttachmentBytes))
                SettingsNote("The database includes \(bytes(app.maintenance.usage.bodyBytes)) of message bodies and \(bytes(app.maintenance.usage.resourceBytes)) of inline images. Copies saved to Downloads are separate and stay where you saved them.")
            }
            .padding(Tokens.Space.s3)
        }
    }

    private var budgetBytes: Int64 { Int64(max(budget, 1)) * 1024 * 1024 }

    private func errorMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
