# Local mail data security decision

Tern caches message headers, bodies, drafts, pending actions, and calendar data in SQLite under its macOS Application Support directory. The databases are plaintext. OAuth and ChatGPT credentials are stored separately in Keychain.

## Decision

The supported local threat boundary is the signed, sandboxed app account and the user's encrypted macOS volume. Tern must keep its Application Support directory accessible only to its owner (`0700`), and users handling sensitive mail should keep FileVault enabled. The app does not claim to keep cached mail secret from software already running as the same macOS user, a process with Full Disk Access, or a backup made while the volume is unlocked.

This decision preserves local full-text search, offline reading, and recoverable unsent drafts without introducing a second database key that would also need to be available to the running app. If the product's threat model expands to hostile same-user processes or unencrypted backups, the cache must move to authenticated database encryption with a Keychain-managed key and a tested migration for existing databases. File permissions alone would not meet that stronger requirement.

The cache and attachment folders are deleted on account removal where possible. Exported or opened attachments may also exist outside the app container by explicit user action and follow the destination's own protection settings.
