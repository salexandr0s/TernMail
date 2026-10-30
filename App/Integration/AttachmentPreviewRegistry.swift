import Foundation
import SwiftUI

/// A view owns one idempotent lease. Two previews of one file keep it until
/// both close; repeated onAppear/onChange updates never add duplicate leases.
@MainActor final class AttachmentPreviewRegistry {
    static let shared = AttachmentPreviewRegistry()
    private var previews: [UUID: URL] = [:]
    var activeURLs: Set<URL> { Set(previews.values) }

    func update(_ url: URL?, lease: UUID) {
        previews[lease] = url?.standardizedFileURL.resolvingSymlinksInPath()
    }
    func release(_ lease: UUID) { previews.removeValue(forKey: lease) }
}

private struct AttachmentPreviewLease: ViewModifier {
    let url: URL?
    @State private var lease = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear { AttachmentPreviewRegistry.shared.update(url, lease: lease) }
            .onChange(of: url) { _, url in AttachmentPreviewRegistry.shared.update(url, lease: lease) }
            .onDisappear { AttachmentPreviewRegistry.shared.release(lease) }
    }
}

extension View {
    func protectAttachmentPreview(_ url: URL?) -> some View { modifier(AttachmentPreviewLease(url: url)) }
}
