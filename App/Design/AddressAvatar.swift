import MailStore
import SwiftUI

extension EnvironmentValues {
    @Entry var addressAvatarContext = AddressAvatarContext.empty
}

/// Scene roots supply photo access without making standalone avatars depend on AppModel.
struct AddressAvatarEnvironment: ViewModifier {
    let app: AppModel

    func body(content: Content) -> some View {
        let owners = app.mailbox?.accounts.map(\.account) ?? []
        let profiles = owners.reduce(into: [String: String]()) { $0[$1.email.lowercased()] = $1.id }
        let identity = app.mailbox.map { String(describing: ObjectIdentifier($0)) } ?? "signed-out"
        content.environment(\.addressAvatarContext,
            AddressAvatarContext(cache: app.cache, accounts: app.settingsAccountStore,
                                 profileAccountIDs: profiles, identity: identity))
    }
}

struct AddressAvatar<Placeholder: View>: View {
    let accountID: String?
    let address: String
    let name: String
    let size: CGFloat
    private let contextOverride: AddressAvatarContext?
    private let placeholder: Placeholder
    @Environment(\.addressAvatarContext) private var environmentContext
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = DomainLogoPreferences.defaultEnabled
    @State private var model: AddressAvatarModel
    @State private var configuredIdentity: String?

    init(accountID: String? = nil, address: String, name: String = "", size: CGFloat = Tokens.Control.avatar,
         context: AddressAvatarContext? = nil, model: AddressAvatarModel = AddressAvatarModel(),
         @ViewBuilder placeholder: () -> Placeholder) {
        self.accountID = accountID; self.address = address; self.name = name; self.size = size
        self.contextOverride = context; self.placeholder = placeholder()
        _model = State(initialValue: model)
    }

    private var context: AddressAvatarContext { contextOverride ?? environmentContext }
    private var identity: String { "\(accountID ?? "")|\(address.lowercased())|\(context.identity)|\(showsLogos)" }

    private var displayedImage: NSImage? {
        if configuredIdentity == identity {
            return !model.isLogo || showsLogos ? model.image : nil
        }
        if let profile = model.cachedProfilePhoto(for: address, context: context) { return profile }
        guard showsLogos, accountID == nil || context.cache == nil || context.accounts == nil else { return nil }
        return DomainLogoThumbnailCache.shared.image(for: address)
    }

    var body: some View {
        Group {
            if let image = displayedImage {
                AvatarImage(image: image, size: size)
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear(perform: configure)
        .onChange(of: identity) { _, _ in configure() }
        // A lazy row can disappear while SwiftUI retains its state. The model
        // keeps its pixels and access observation until that state is released.
    }

    private func configure() {
        configuredIdentity = identity
        model.configure(address: address, accountID: accountID, context: context, showsLogos: showsLogos)
    }
}

extension AddressAvatar where Placeholder == TernAvatar {
    init(accountID: String? = nil, address: String, name: String = "", size: CGFloat = Tokens.Control.avatar) {
        self.init(accountID: accountID, address: address, name: name, size: size) {
            TernAvatar(name: name.isEmpty ? address : name, size: size)
        }
    }
}
