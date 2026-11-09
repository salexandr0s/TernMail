import GRDB

extension Configuration {
    /// For a database file that more than one connection can open at once.
    /// The Focus filter and account removal may open a second connection
    /// while the app writes. A write that overlaps another one then waits up
    /// to 5 seconds instead of failing at once with "database is locked".
    static var sharedFile: Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        return configuration
    }
}
