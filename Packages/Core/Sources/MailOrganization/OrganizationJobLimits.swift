/// Bounds shared by mailbox scanning, analysis and reviewed application.
public enum OrganizationJobLimits {
    public static let maximumMessages = 100_000
    public static let defaultMessages = 5_000
    public static let analysisBatchSize = 200
    public static let maximumCategories = 40
    public static let maximumRuleSenders = 1_000
}
