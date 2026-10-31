import AppKit
import MailStore
import MessageContent
import Observation

/// Photo access is scoped to the owner; only public logos are shared between accounts.
struct AddressAvatarContext: Sendable {
    let cache: MailCache?
    let accounts: AccountStore?
    let profileAccountIDs: [String: String]
    let identity: String

    static let empty = AddressAvatarContext()

    init(cache: MailCache? = nil, accounts: AccountStore? = nil,
         profileAccountIDs: [String: String] = [:], identity: String = "none") {
        self.cache = cache
        self.accounts = accounts
        self.profileAccountIDs = profileAccountIDs
        self.identity = identity + profileAccountIDs.sorted { $0.key < $1.key }
            .map { "|\($0.key):\($0.value)" }.joined()
    }
}

@MainActor @Observable
final class AddressAvatarModel {
    typealias LogoLoader = @Sendable (String) async -> Data?
    private(set) var image: NSImage?
    private(set) var isLogo = false
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let logoLoader: LogoLoader
    @ObservationIgnored private let profilePhoto: @MainActor (String) -> NSImage?
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var accessTask: Task<Void, Never>?
    @ObservationIgnored private var photoTask: Task<Void, Never>?
    @ObservationIgnored private var logoTask: Task<Void, Never>?
    @ObservationIgnored private var profileImage: NSImage?
    @ObservationIgnored private var contactImage: NSImage?
    @ObservationIgnored private var logoImage: NSImage?
    @ObservationIgnored private var contactsResolved = false
    @ObservationIgnored private var logoAttempted = false

    init(logoLoader: @escaping LogoLoader = { await DomainLogoImages.shared.data(for: $0) },
         profilePhoto: @escaping @MainActor (String) -> NSImage? = { AccountProfileImages.shared.image(for: $0) }) {
        self.logoLoader = logoLoader
        self.profilePhoto = profilePhoto
    }

    func configure(address: String, accountID: String?, context: AddressAvatarContext,
                   showsLogos: Bool, preferredAccountID: String? = nil) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let current = Request(address: address, accountID: accountID, contextID: context.identity,
                              showsLogos: showsLogos, profileID: preferredAccountID ?? context.profileAccountIDs[address])
        guard request != current else { return }
        stop()
        request = current
        let token = generation
        guard EmailAddress(address: address).isValid else { return }
        watchProfile(current.profileID, generation: token)
        guard let owner = accountID, let cache = context.cache, let accounts = context.accounts else {
            contactsResolved = true
            refresh(generation: token)
            return
        }
        accessTask = Task { [weak self] in
            do {
                var previous: Bool?
                for try await enabled in accounts.observeContactAccess(accountID: owner) {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    guard previous != enabled else { continue }
                    previous = enabled
                    self.photoTask?.cancel()
                    self.contactImage = nil
                    self.contactsResolved = !enabled
                    self.refresh(generation: token)
                    guard enabled else { continue }
                    self.photoTask = Task { [weak self] in
                        do {
                            for try await record in cache.observeContactPhoto(accountID: owner, address: address) {
                                guard !Task.isCancelled else { return }
                                let photo: NSImage?
                                if let record {
                                    photo = await ContactPhotoImages.image(for: record, address: address, cache: cache, accounts: accounts)
                                } else { photo = nil }
                                guard let self, self.generation == token, !Task.isCancelled else { return }
                                self.contactImage = photo
                                self.contactsResolved = true
                                self.refresh(generation: token)
                            }
                        } catch {
                            guard let self, self.generation == token, !Task.isCancelled else { return }
                            self.contactImage = nil
                            self.contactsResolved = true
                            self.refresh(generation: token)
                        }
                    }
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.photoTask?.cancel()
                self.contactImage = nil
                self.contactsResolved = true
                self.refresh(generation: token)
            }
        }
    }

    func stop() {
        generation = UUID()
        request = nil
        accessTask?.cancel(); accessTask = nil
        photoTask?.cancel(); photoTask = nil
        logoTask?.cancel(); logoTask = nil
        profileImage = nil; contactImage = nil; logoImage = nil
        contactsResolved = false; logoAttempted = false
        publish(nil, isLogo: false)
    }

    private func watchProfile(_ id: String?, generation token: UUID) {
        guard generation == token else { return }
        profileImage = withObservationTracking {
            id.flatMap { profilePhoto($0) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchProfile(id, generation: token) }
        }
        refresh(generation: token)
    }

    private func refresh(generation token: UUID) {
        guard generation == token, let request else { return }
        if let photo = profileImage ?? contactImage {
            logoTask?.cancel(); logoTask = nil
            logoAttempted = false
            publish(photo, isLogo: false)
            return
        }
        guard contactsResolved, request.showsLogos else {
            logoTask?.cancel(); logoTask = nil
            logoAttempted = false
            publish(nil, isLogo: false)
            return
        }
        if let logoImage { publish(logoImage, isLogo: true); return }
        publish(nil, isLogo: false)
        guard !logoAttempted else { return }
        logoAttempted = true
        let load = logoLoader
        logoTask = Task { [weak self] in
            let data = await load(request.address)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.logoTask = nil
            self.logoImage = data.flatMap(NSImage.init(data:))
            self.publish(self.profileImage ?? self.contactImage ?? self.logoImage,
                         isLogo: self.profileImage == nil && self.contactImage == nil && self.logoImage != nil)
        }
    }

    private func publish(_ value: NSImage?, isLogo: Bool) {
        guard image !== value || self.isLogo != isLogo else { return }
        image = value
        self.isLogo = isLogo
        onChange?()
    }

    deinit { accessTask?.cancel(); photoTask?.cancel(); logoTask?.cancel() }

    private struct Request: Equatable {
        let address: String
        let accountID: String?
        let contextID: String
        let showsLogos: Bool
        let profileID: String?
    }
}
