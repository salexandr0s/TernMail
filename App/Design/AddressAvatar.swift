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
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = true
    @State private var model = AddressAvatarModel()
    @State private var configuredIdentity: String?

    init(accountID: String? = nil, address: String, name: String = "", size: CGFloat = Tokens.Control.avatar,
         context: AddressAvatarContext? = nil, @ViewBuilder placeholder: () -> Placeholder) {
        self.accountID = accountID; self.address = address; self.name = name; self.size = size
        self.contextOverride = context; self.placeholder = placeholder()
    }

    private var context: AddressAvatarContext { contextOverride ?? environmentContext }
    private var identity: String { "\(accountID ?? "")|\(address.lowercased())|\(context.identity)|\(showsLogos)" }

    var body: some View {
        Group {
            if configuredIdentity == identity, !model.isLogo || showsLogos, let image = model.image {
                AvatarImage(image: image, size: size)
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear(perform: configure)
        .onChange(of: identity) { _, _ in configure() }
        .onDisappear { model.stop() }
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
