import AppKit
import SwiftUI

/// Website icons supplement missing photos without changing images inside mail.
struct DomainLogoAvatar<Placeholder: View>: View {
    let address: String
    let size: CGFloat
    let allowsLookup: Bool
    private let placeholder: Placeholder
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = true
    @State private var image: NSImage?
    @State private var loadedAddress: String?

    init(address: String, size: CGFloat = Tokens.Control.avatar, allowsLookup: Bool = true,
         @ViewBuilder placeholder: () -> Placeholder) {
        self.address = address
        self.size = size
        self.allowsLookup = allowsLookup
        self.placeholder = placeholder()
    }

    private var request: Request {
        Request(address: address.lowercased(), enabled: showsLogos && allowsLookup)
    }

    var body: some View {
        Group {
            if request.enabled, loadedAddress == request.address, let image {
                AvatarImage(image: image, size: size)
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: request) {
            image = nil
            loadedAddress = nil
            let current = request
            guard current.enabled else { return }
            let data = await DomainLogoImages.shared.data(for: current.address)
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
            loadedAddress = current.address
        }
    }

    private struct Request: Hashable {
        let address: String
        let enabled: Bool
    }
}
