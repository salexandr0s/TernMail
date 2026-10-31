import AppKit
import MailStore
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentOpenLocation: String, CaseIterable {
    case application
    case downloads
    static let key = "attachmentOpenLocation"
}

/// Opening never replaces a user's Downloads file. Save panels own replacement consent.
@MainActor
enum AttachmentActions {
    static func openingURL(_ source: URL) async throws -> URL {
        guard UserDefaults.standard.string(forKey: AttachmentOpenLocation.key) == AttachmentOpenLocation.downloads.rawValue else { return source }
        let folder = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appending(path: "Tern", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await AttachmentFileExport.copyWithoutReplacing(source, to: folder)
    }

    static func open(_ source: URL) async throws {
        let file = try await openingURL(source)
        guard NSWorkspace.shared.open(file) else { throw CocoaError(.fileReadUnknown) }
    }

    static func openWith(_ source: URL) async throws {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let application = panel.url else { return }
        let file = try await openingURL(source)
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: application, configuration: .init())
    }

    static func copy(_ source: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([source as NSURL])
    }

    /// Returns where the file went, or nil when the panel was cancelled.
    @discardableResult
    static func save(_ source: URL, filename: String) async throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentFileExport.safeFilename(filename)
        panel.canCreateDirectories = true
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let destination = panel.url else { return nil }
        try await AttachmentFileExport.save(source, to: destination)
        return destination
    }

    /// How many of `files` reached the chosen folder, or nil when the panel was cancelled.
    /// A file that fails to copy is skipped, so the rest still arrive.
    static func saveAll(_ files: [URL]) async -> Int? {
        guard !files.isEmpty else { return 0 }
        let panel = NSOpenPanel()
        panel.title = "Save All Attachments"
        panel.prompt = "Save"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let directory = panel.url else { return nil }
        var saved = 0
        for file in files where (try? await AttachmentFileExport.copyWithoutReplacing(file, to: directory)) != nil { saved += 1 }
        return saved
    }
}

struct AttachmentPreferencesView: View {
    @AppStorage(AttachmentOpenLocation.key) private var location = AttachmentOpenLocation.application.rawValue

    var body: some View {
        SettingsPage {
            Section("Opening attachments") {
                SettingsControlRow("Open attachments from") {
                    Picker("Open attachments from", selection: $location) {
                        Text("Tern's attachment folder").tag(AttachmentOpenLocation.application.rawValue)
                        Text("Downloads → Tern").tag(AttachmentOpenLocation.downloads.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Text(location == AttachmentOpenLocation.downloads.rawValue
                    ? "Opening from Downloads saves a separate copy. Existing files are kept."
                    : "Attachments open from Tern's local storage. Use Save to keep a copy in a folder you choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tokens.Space.s4)
                    .padding(.bottom, Tokens.Space.s2)
            }
        }
    }
}
