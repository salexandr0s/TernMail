# Tern security review and remediation plan

Date: 31 October 2026  
Repository revision: `0ea55114f210efec279332599e7309c56827278d` plus local, pre-existing working-tree edits  
Method: Authorized, read-only Codex CLI review with `daybreak=true`, model `gpt-6-sol`, followed by manual source verification. Codex CLI version was 0.166.0. No live targets were contacted, no exploit was run, and no tests were run for this review.

## Executive summary

Two credible issues were found:

| ID | Finding | Severity | Confidence | Immediate action |
| --- | --- | --- | --- | --- |
| TERN-SEC-01 | Default-on sender website icon requests reveal IP address and timing even while remote message images are blocked | Medium | High | Turn off **Show company logos** until an explicit opt-in is implemented. |
| TERN-SEC-02 | Sign-out suppresses Keychain and file deletion failures, leaving no reliable retry path after account and cache records are removed | Low | High | Treat incomplete local cleanup as a visible, retryable sign-out state. |

Severity reflects a local macOS mail client. Neither finding demonstrates remote code execution, token exfiltration by a remote sender, or automatic mail transmission. The first is a privacy design flaw with a remote observer; the second depends on a local deletion failure.

## Scope and trust boundaries

Tern receives sender-controlled addresses, headers, HTML, MIME parts, attachments, calendar invitations, and links from Gmail. It also receives local URL-handler events and files selected by the user. The review followed those inputs toward WebKit, network requests, file writes, the Keychain, SQLite, OAuth callbacks, scripting, and assistant tools.

The protected assets are mailbox content, Google and ChatGPT credentials, local attachment copies, the user's IP address and activity timing, and the integrity of outgoing mail and calendar actions. The relevant boundaries are between an email sender and the local app, between the app and a sender's website, and between sign-out state and data retained by macOS.

## TERN-SEC-01: Default-on logo lookups expose activity

**Severity:** Medium. **Confidence:** High. **Status:** Source-verified; no live network reproduction.

### Attack path and evidence

1. A sender uses an address at a domain they control and sends mail to the user. A visible message-list row derives the avatar address from message sender metadata (`App/Views/MessageListRow.swift:29-33`).
2. `AddressAvatar` reads `showCompanyLogos` with a default of `true` (`App/Design/AddressAvatar.swift:37`). When there is no profile or contact photo, `AddressAvatarModel` starts the logo loader (`App/Design/AddressAvatarModel.swift:130-150`). Other avatar surfaces also default to `true` (`App/Design/DomainLogoAvatar.swift:10,38-43`).
3. `DomainLogoImages` reduces the address to its registrable domain and requests that website's home page and icon paths (`App/Design/DomainLogoImages.swift:47-55,59-84,238-267`). The request is triggered by displaying the avatar, not by the per-message **Load Images** action.
4. **Block remote images** also defaults to `true`, while **Show company logos** defaults to `true` independently (`App/Settings/ReadingSettingsView.swift:4,11,64-67`). The setting text correctly discloses that websites receive the user's IP address, but a new user need not have opened Settings before the first lookup.

The sender-controlled website can observe the connection's public IP address and request time. A sender could correlate this with delivery or a recipient-specific domain. The request does **not** include the email address, message body, Gmail token, cookies, or referrer; the existing request code and `Tests/AppTests/DomainLogoImagesTests.swift:62-81` support that limit. Cached icons can also prevent repeat requests. The signal is therefore weaker than a message-specific tracking pixel but still bypasses the expected privacy posture of blocking remote content by default.

### Fix plan

1. Make company-logo lookup an explicit opt-in. Change every `@AppStorage(DomainLogoImages.preferenceKey)` default to `false` and route all avatar surfaces through one effective privacy preference. Keep initials or existing local contact photos as the default fallback.
2. Migrate existing installations deliberately. A missing `showCompanyLogos` key currently means the default-on behavior, so treat missing as no consent and switch it off on upgrade. Preserve a stored `true` only if it reliably represents an explicit user choice; otherwise use a versioned consent flag and ask again. Explain the IP/timing exposure before enabling lookups.
3. Keep the setting description beside the consent control. State that rendering a message-list row can fetch from a sender's website even if message images stay blocked. If product requirements demand default-on logos, use a vetted image proxy that does not reveal the user's IP address to the sender domain and assess the proxy's own privacy obligations.
4. Add a regression test with an injected logo transport: a fresh profile with blocked remote images must issue zero sender-domain requests while rows and message cards render; an explicit opt-in may issue a request; switching off cancels pending lookups and prevents new ones.

**Acceptance criteria:** No sender-domain DNS or HTTP request occurs from any avatar surface before opt-in. The UI states the network disclosure before opt-in. Existing users are migrated to a known consent state.

## TERN-SEC-02: Sign-out can leave credentials or files behind

**Severity:** Low. **Confidence:** High. **Status:** Source-verified; failure injection remains to be done.

### Failure path and evidence

1. `removeAccountData` deletes the account record first (`App/AppModel.swift:929-938`). It then signs out the session and independently attempts a Keychain deletion (`App/AppModel.swift:939-941`).
2. `AccountSession.signOut()` clears the in-memory state, queues Keychain deletion, and suppresses any error (`App/Auth/AccountSession.swift:70-76`). The second Keychain deletion in `removeAccountData` also suppresses errors. A transient Keychain authorization or I/O failure can therefore leave the saved Google session while the UI proceeds as if the account were removed.
3. `removeCachedData` deletes cache rows before attempting attachment and outgoing-draft directory removal; those file-removal errors are suppressed (`App/AppModel.swift:958-976`).
4. Next-launch cleanup discovers stale accounts from cache rows (`App/AppModel.swift:948-953`). After successful row deletion, it has no account ID or draft IDs with which to retry failed file removal. An orphaned Keychain item is likewise not found through the deleted account record.

This does not give a remote sender access to a credential. It matters when a user signs out to remove sensitive local data, especially before sharing or disposing of a Mac. The precise impact depends on macOS file and Keychain access controls and on the cause of the cleanup failure. The code currently provides no durable proof that removal completed.

### Fix plan

1. Create a durable cleanup journal in the account/configuration store before deleting the account record. Store the account ID, affected draft IDs or directories, and the pending cleanup steps. Avoid storing secret bytes in the journal.
2. Make `AccountSession.signOut()` return or throw the Keychain deletion result. Treat “item not found” and “file not found” as successful cleanup, while preserving other failures for retry. Keep the in-memory session unusable immediately.
3. Retry pending Keychain and file deletion on launch and after sign-out. Remove the journal entry only after all steps succeed. Ensure a failed cache transaction leaves enough information for the next attempt.
4. Show a clear “local data removal incomplete” notice with a retry action. Do not describe sign-out as complete while cleanup remains pending. Avoid printing credential values or private file paths in logs.
5. Add failure-injection tests for Keychain deletion, received-attachment directory deletion, and outgoing-draft directory deletion. Verify that account access is disabled immediately, the journal survives restart, the next attempt removes the orphaned data, and unrelated accounts remain untouched.

**Acceptance criteria:** Every deletion failure is either reported and retryable or proven harmless. A restart can finish cleanup after failure at each step. No credential or account-specific file remains after the journal entry is cleared.

## Prioritized delivery plan

| Phase | Work | Verification | Completion gate |
| --- | --- | --- | --- |
| 1 | Ship the logo consent default and migration | Injected network transport tests across message list, thread, attachment library, and assistant cards | Zero sender-domain requests before consent |
| 2 | Add durable sign-out cleanup journal and explicit errors | Injected Keychain and filesystem failures, including restart | Incomplete removal is visible and retries succeed |
| 3 | Review the changes in Codex Security/Daybreak and run the normal app and Core test suites | Security diff review, `swift test --package-path Packages/Core`, Xcode app tests | Findings closed with regression evidence |

## Coverage and limits

The review inspected Google OAuth callback handling and Keychain storage, ChatGPT loopback callback validation, WebKit message and print rendering, HTML/MIME/link handling, attachment path construction, Gmail and calendar request construction, AppleScript exposure, custom URL routing, and assistant tool scoping. No additional credible vulnerability was established in those areas. That is not a guarantee that they are vulnerability-free.

This was source and test inspection of the current local checkout. The repository had unrelated, pre-existing edits in `App/Views/MessageListRow.swift`, `App/Views/ThreadListView.swift`, and `SESSION_HANDOFF.md`. No dependency audit, binary analysis, live provider test, network interception, fuzzing, or dynamic exploit validation was performed. The above findings should be rechecked after fixes and against the release build.
