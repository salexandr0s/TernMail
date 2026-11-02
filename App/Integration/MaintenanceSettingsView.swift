import MailStore
import SwiftUI

struct MaintenanceSettingsView: View {
    let app: AppModel
    @AppStorage(CacheMaintenanceModel.budgetKey) private var budget = CacheMaintenanceModel.defaultBudgetMiB
    @State private var trimRequest: TrimRequest?
    @State private var confirmsReset = false
    @State private var resetError: String?

    /// Budget choices are powers of two, so binary units keep them round.
    @MainActor private static let sizes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    var body: some View {
        SettingsPage {
            usageSummary
            Section {
                SettingsControlRow("Cache budget", detail: "Older mail and managed attachment copies are trimmed first.") {
                    Picker("Cache budget", selection: $budget) {
                        ForEach(CacheMaintenanceModel.budgetChoices, id: \.self) { size in
                            Text(bytes(Int64(size) * 1024 * 1024)).tag(size)
                        }
                    }
                    .fixedSize()
                }
                LabeledContent {
                    HStack(spacing: Tokens.Space.s2) {
                        if app.maintenance.isRefreshing || app.maintenance.isTrimming {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(app.maintenance.isTrimming ? "Trimming cache" : "Measuring cache")
                        }
                        Button("Refresh Size") { Task { await app.maintenance.refresh() } }
                            .fixedSize()
                            .disabled(app.maintenance.isRefreshing)
                        Button("Trim Now…") { trimRequest = .manual }
                            .fixedSize()
                            .disabled(app.maintenance.readiness == nil)
                    }
                    .disabled(app.maintenance.isTrimming || app.isResettingCache)
                } label: {
                    Text("Downloaded mail")
                }
                if let status = app.maintenance.status {
                    SettingsNote(status, systemImage: app.maintenance.protectedBudgetLimit ? "lock.shield" : "checkmark.circle")
                }
                if let error = app.maintenance.error { SettingsErrorLabel(error) }
            } header: {
                Text("Cache management")
            } footer: {
                Text("Open conversations, drafts, pending changes and pending alerts stay protected.")
            }
            Section {
                LabeledContent {
                    Button("Reset Mail Cache…", role: .destructive) { confirmsReset = true }
                        .fixedSize()
                        .disabled(app.maintenance.readiness?.canReset != true || app.maintenance.isTrimming || app.isResettingCache)
                } label: {
                    Text("Downloaded mail")
                }
                if let readiness = app.maintenance.readiness, !readiness.canReset {
                    SettingsNote("Reset is unavailable: \(readiness.localDraftCount) local drafts, \(readiness.activeActionCount) pending changes and \(readiness.failedActionCount) failed changes. Send or discard drafts, and finish or discard changes first.", systemImage: "exclamationmark.circle")
                }
                if app.isResettingCache { ProgressView("Rebuilding mail…").controlSize(.small) }
                if let resetError { SettingsErrorLabel(resetError) }
            } header: {
                Text("Reset")
            } footer: {
                Text("Rebuild downloaded mail from Gmail. Accounts, profiles, templates, signatures, saved searches and Calendar data stay on this Mac.")
            }
        }
        .task { await app.maintenance.refresh() }
        .onChange(of: budget) { _, _ in
            if app.maintenance.totalBytes > budgetBytes { trimRequest = .budgetChange }
        }
        .ternConfirm(trimRequest?.title ?? "", item: $trimRequest, actionTitle: "Trim Now", message: trimRequest?.message ?? "") { _ in
            Task { await app.maintenance.enforceBudget() }
        }
        .ternConfirm("Reset downloaded mail?", isPresented: $confirmsReset, actionTitle: "Reset Mail Cache",
                     message: "Tern downloads mail again after the reset. Your Google accounts and saved settings are kept.") {
            Task {
                do { try await app.resetMailCache(); resetError = nil }
                catch { resetError = "Couldn't reset the cache. Make sure all drafts and pending changes are finished." }
                await app.maintenance.refresh()
            }
        }
    }

    private var usageSummary: some View {
        Section {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Used")
                    Spacer(minLength: Tokens.Space.s3)
                    Text("\(bytes(app.maintenance.totalBytes)) of \(bytes(budgetBytes))")
                        .font(.title3.weight(.medium))
                        .monospacedDigit()
                }
                ProgressView(value: Double(min(app.maintenance.totalBytes, budgetBytes)), total: Double(budgetBytes))
                    .tint(app.maintenance.totalBytes > budgetBytes ? Tokens.Status.warning : .accentColor)
                    .accessibilityLabel("Mail cache usage")
                    .accessibilityValue("\(bytes(app.maintenance.totalBytes)) of \(bytes(budgetBytes))")
            }
            LabeledContent("Database", value: bytes(app.maintenance.usage.databaseBytes))
            LabeledContent("Downloaded attachments", value: bytes(app.maintenance.usage.downloadedAttachmentBytes))
                .monospacedDigit()
        } header: {
            Text("On this Mac")
        } footer: {
            Text("The database includes \(bytes(app.maintenance.usage.bodyBytes)) of message bodies and \(bytes(app.maintenance.usage.resourceBytes)) of inline images. Copies saved to Downloads are separate and stay where you saved them.")
        }
    }

    private var budgetBytes: Int64 { Int64(max(budget, 1)) * 1024 * 1024 }

    private func bytes(_ value: Int64) -> String { Self.sizes.string(fromByteCount: value) }

    /// Trimming removes data, so both routes to it ask first.
    private enum TrimRequest {
        case manual
        case budgetChange

        var title: String {
            switch self {
            case .manual: "Trim the mail cache now?"
            case .budgetChange: "Trim to the new budget now?"
            }
        }

        var message: String {
            switch self {
            case .manual:
                "Older mail and attachment copies are removed from this Mac until the cache fits its budget. Open conversations, drafts and pending changes stay, and Tern downloads trimmed mail again when you open it."
            case .budgetChange:
                "The cache is larger than the new budget. Trimming removes older mail and attachment copies from this Mac; open conversations, drafts and pending changes stay. If you wait, Tern trims during its next maintenance pass."
            }
        }
    }
}
