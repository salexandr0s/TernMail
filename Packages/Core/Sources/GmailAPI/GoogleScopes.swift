import Foundation

/// A part of Tern that needs more Google access than mail. Accounts store
/// the raw values of the features turned on.
public enum AccountFeature: String, Sendable, CaseIterable {
    /// Filter, vacation and signature edits.
    case gmailSettings
    /// Address suggestions from saved contacts, other contacts and, for
    /// Workspace accounts, the directory.
    case contacts
    /// IMAP IDLE on the Inbox.
    case inboxUpdates
    /// Confirmed permanent deletion from Spam or Trash.
    case permanentDeletion
    /// Google calendar events, calendar list and availability.
    case calendar
    /// Create and change calendar properties.
    case calendarManagement
    /// Manage sharing permissions on owned calendars.
    case calendarSharing

    /// The features `names` lists. Names this version doesn't know are skipped.
    public static func named(_ names: some Sequence<String>) -> Set<AccountFeature> {
        Set(names.compactMap(AccountFeature.init(rawValue:)))
    }

    /// Raw values in declaration order, for storing.
    public static func names(of features: Set<AccountFeature>) -> [String] {
        allCases.filter(features.contains).map(\.rawValue)
    }
}

/// The OAuth scopes Tern asks Google for.
public enum GoogleScopes {
    public static let gmailModify = "https://www.googleapis.com/auth/gmail.modify"
    public static let gmailSettings = "https://www.googleapis.com/auth/gmail.settings.basic"
    public static let contacts = "https://www.googleapis.com/auth/contacts.readonly"
    public static let otherContacts = "https://www.googleapis.com/auth/contacts.other.readonly"
    public static let directory = "https://www.googleapis.com/auth/directory.readonly"
    public static let fullMail = "https://mail.google.com/"
    public static let calendarEvents = "https://www.googleapis.com/auth/calendar.events"
    public static let calendarList = "https://www.googleapis.com/auth/calendar.calendarlist"
    public static let calendarFreeBusy = "https://www.googleapis.com/auth/calendar.events.freebusy"
    public static let calendarManagement = "https://www.googleapis.com/auth/calendar.calendars"
    public static let calendarSharing = "https://www.googleapis.com/auth/calendar.acls"
    public static let fullCalendar = "https://www.googleapis.com/auth/calendar"

    /// Asked for at every authorization: the account's identity and its mail.
    public static let base = ["openid", "email", "profile", gmailModify]

    /// New accounts request contact suggestions and photos during sign-in.
    /// Contacts stays optional if the user declines either scope.
    public static let initialFeatures: Set<AccountFeature> = [.contacts]

    /// A returning account keeps its choices, including turning Contacts off.
    public static func featuresForSignIn(storedFeatures: [String]?) -> Set<AccountFeature> {
        storedFeatures.map(AccountFeature.named) ?? initialFeatures
    }

    /// The scopes `feature` can't work without.
    public static func required(for feature: AccountFeature) -> [String] {
        switch feature {
        case .gmailSettings: [gmailSettings]
        case .contacts: [contacts, otherContacts]
        case .inboxUpdates, .permanentDeletion: [fullMail]
        case .calendar: [calendarEvents, calendarList, calendarFreeBusy]
        case .calendarManagement: [calendarManagement]
        case .calendarSharing: [calendarSharing]
        }
    }

    /// The scopes for an authorization with `features` on: `base`, then each
    /// feature's, each once. Workspace accounts also get the directory, which
    /// Contacts works without.
    public static func request(features: Set<AccountFeature>, isWorkspace: Bool) -> [String] {
        var scopes = base
        for feature in AccountFeature.allCases where features.contains(feature) {
            scopes += required(for: feature)
            if feature == .contacts, isWorkspace { scopes.append(directory) }
        }
        var seen = Set<String>()
        return scopes.filter { seen.insert($0).inserted }
    }

    /// Whether `granted` covers every scope `feature` needs.
    public static func isCovered(_ feature: AccountFeature, by granted: some Collection<String>) -> Bool {
        required(for: feature).allSatisfy { isCovered($0, by: granted) }
    }

    /// The stored features `granted` still covers. Names this version doesn't
    /// know are dropped.
    public static func covered(_ names: [String], by granted: some Collection<String>) -> Set<AccountFeature> {
        AccountFeature.named(names).filter { isCovered($0, by: granted) }
    }

    /// Whether `granted` covers `scope`. Google may grant a broader scope
    /// than the one asked for, and that counts.
    public static func isCovered(_ scope: String, by granted: some Collection<String>) -> Bool {
        granted.contains(scope) || broader[scope, default: []].contains(where: granted.contains)
    }

    /// Broader scopes that do everything the key scope does. Only pairs
    /// whose methods list both scopes; anything else counts as missing.
    static let broader: [String: [String]] = [
        gmailModify: [fullMail],
        contacts: ["https://www.googleapis.com/auth/contacts"],
        calendarEvents: [fullCalendar],
        calendarList: [fullCalendar],
        calendarFreeBusy: [fullCalendar, "https://www.googleapis.com/auth/calendar.readonly"],
        calendarManagement: [fullCalendar],
        calendarSharing: [fullCalendar],
    ]
}

/// What a new grant gives an account.
public struct FeatureGrant: Sendable, Equatable {
    public enum Rejection: Error, Sendable, Equatable {
        /// The user chose a different Google account in the browser.
        case otherAccount
        /// The user unticked mail access on the consent screen.
        case mailAccessNotGranted
    }

    /// The features asked for that the grant covers.
    public var features: Set<AccountFeature>
    /// Required scopes the grant lacks, for the features it leaves off.
    public var missingScopes: [String]

    /// Checks the grant from an authorization that asked for `features`.
    /// With `accountID`, it must come from that account.
    ///
    /// - Throws: `Rejection` when the grant has to be thrown away, so the
    ///   account keeps its old session.
    public init(subject: String, granted: [String], accountID: String?, features: Set<AccountFeature>) throws {
        if let accountID, subject != accountID { throw Rejection.otherAccount }
        guard GoogleScopes.isCovered(GoogleScopes.gmailModify, by: granted) else { throw Rejection.mailAccessNotGranted }
        var covered = Set<AccountFeature>()
        var missing: [String] = []
        for feature in AccountFeature.allCases where features.contains(feature) {
            let lacking = GoogleScopes.required(for: feature).filter { !GoogleScopes.isCovered($0, by: granted) }
            if lacking.isEmpty {
                covered.insert(feature)
            } else {
                missing += lacking
            }
        }
        self.features = covered
        missingScopes = missing
    }
}
