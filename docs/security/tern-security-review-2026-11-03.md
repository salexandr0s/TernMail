# Tern security assessment and remediation

Date: 3 November 2026

Baseline: `4df61fd80a32a6f6a1d8503f79a8cbccd40c5451` plus the security changes in this commit.

This report combines the securecoding review and the separate “Run TernMail security assessment” chat. The reviews found no confirmed critical or high severity vulnerability. The findings below have been remediated with regression coverage. The local storage threat model remains unchanged.

## High-risk areas

1. Sender-controlled HTML and network destinations cross from Gmail content into WebKit and native HTTP clients. Image consent must not grant access to arbitrary resources or private networks.
2. Sender identity controls remembered image permission. A displayed From address alone cannot establish that identity.
3. Account removal crosses persistent configuration, credentials, mail and calendar caches, and attachment files. A failed deletion must survive a restart without restoring account access.
4. OAuth callback sockets share a bounded loopback listener. An idle client must not occupy every slot for the full sign-in period.

## Findings and fixes

| Finding | Severity and evidence | Remediation and regression evidence |
| --- | --- | --- |
| Direct remote resources could bypass the intended image loader, including escaped CSS URLs after image consent. Consented HTTPS images could also target private addresses. | Medium privacy risk for loading resources outside the consent boundary; private-network access was a defense-in-depth gap. Source review established the paths. The regression uses a synthetic loopback connection probe with a positive control. | `MessageDocument`, `RemoteImageResourceURL`, `RemoteContentBlocker`, `RemoteImageHandler` and `MessageWebView` use prepared message-scoped capabilities and deny direct WebKit network access. `PinnedRemoteImageClient` validates all DNS answers, connects to one validated public address, preserves hostname TLS verification, rejects redirects, and bounds work. ReadingPrivacyTests, RemoteImageSecurityTests and NewsletterTransportTests cover membership, escaped CSS, consent/scope changes, cancellation, framing and destination checks. |
| Remembered image consent relied on an unverified From address and reusable view state. | Medium privacy risk: a forged sender or reused reader could receive permission intended for another message. | `SenderImagePolicy` requires an unambiguous Gmail receiver DMARC pass aligned with the sole outer From domain. Both manual and remembered permission bind to account, message, sender and authentication evidence. Old cached bodies request fresh evidence once. SenderImagePolicyTests, SenderImageMigrationTests and SenderImageAuthenticationTests cover failed/missing/ambiguous evidence, spoofed headers, migration and identity changes. |
| Account and cache records could disappear before failed credential or file deletions had a durable retry record. | Low severity; source-confirmed cleanup reliability issue requiring a local deletion failure. | `AccountRemovalStore` persists account identity, draft IDs and stage completion independently of the account row. `AccountCleanupCoordinator` retries at startup, hides pending accounts, blocks their reauthorization, drains session credential writes and cleans an unopened calendar cache. AccountRemovalStoreTests and AccountCleanupCoordinatorTests inject failures and reopen stores, check account isolation, validate managed paths and exercise reauthorization ordering. |
| Idle or partial OAuth callback requests could retain all eight connection slots. | Low severity local denial of service against sign-in. | `LoopbackAuthListener` applies an absolute five-second connection deadline, separate from the overall sign-in timeout. Terminal paths close sockets and timers. LoopbackAuthListenerTests exhaust the slots with idle/partial requests, verify a later valid callback, and check cancellation. Disabling the deadline in an isolated mutation made the exhaustion test fail. |
| One-click unsubscribe validated DNS before a second hostname resolution by URLSession. | Conditional low severity: rebinding could direct a blind HTTPS POST to a private destination. The original assessment verified the gap in code without reproducing an exploit. Requests carried no Gmail credentials; redirects were blocked and TLS trust still applied. | `NewsletterUnsubscribeTransport` and `PinnedNewsletterHTTP` connect to a validated numeric address while retaining the original host for SNI and certificate validation. NewsletterTransportTests cover unsafe and mixed DNS answers, pinned destinations, exact context-free requests, redirects, deadlines and bounded response headers. |

Remote image fetches allow at most 128 prepared URLs per message and four concurrent native fetches across all message views. Each fetch has a 20-second deadline, an 8 MiB image limit and a 16 KiB cumulative response-header limit, including interim responses. Chunked bodies decode incrementally. Images remain blocked by default; explicit loading still reveals the user's public address and request timing to the destination.

The sender policy trusts the first Gmail receiver `Authentication-Results` header delivered through the Gmail API. DMARC establishes domain alignment, not individual mailbox ownership. Imported messages with fabricated receiver traces are outside that assumption. Missing or malformed evidence fails closed for remembered consent; a user can still explicitly load images for that message.

## Verification

Two independent source rechecks found no new actionable defects. The isolated publication source snapshot (`c6b35af7837f5675e57d558c99634f2350f3daa4`, before this report and the handoff update) passed all final checks:

- Full Core suite: 790 tests in 130 suites passed with `swift test --package-path Packages/Core --jobs 6 --disable-automatic-resolution`.
- Fresh Debug `xcodebuild build-for-testing` passed without copying local secrets; the exported build used ad-hoc signing.
- Native tests: all 80 tests in nine affected suites passed in one run. The suites were AccountCleanupCoordinatorTests, LoopbackAuthListenerTests, ChatGPTConnectionTests, GoogleAuthTests, RemoteImageSecurityTests, MessageWebViewTests, ReadingPolicyTests, MailboxModelTests and UnsubscribeModelTests. The Tern scheme supplied `--ui-audit` isolation.
- Staged whitespace and credential-shaped literal checks passed. Source hashes confirmed that the tested export matches the staged source and that unrelated working-tree edits were preserved.

Local evidence is in `build/Verification/security-publish-20261103/verification.json`, with Core/build/test logs, an xcresult bundle, the parsed 80 passing test identities and a tested-source manifest. The snapshot excludes unrelated calendar, avatar, reader, mailbox and performance edits from the shared checkout. Release signing and a production installation were not part of these checks.

Earlier implementation checks passed 790 Core tests and 75 selected native tests across an initial run and focused reruns. A cleanup fault fixture required canonical path comparison; its final assertions confirm the injected failure occurred. An existing viewport eviction test passed in isolation after timing out in the combined run. These earlier results cover the shared working tree, rather than the isolated publication snapshot.

The separate assessment inspected authentication, rendering, assistant tool boundaries, attachments, networking, local storage and dependencies. It verified the installed baseline app's code signature and entitlements. Its OSV SwiftURL queries returned no advisories for the three pinned dependencies at the time of that assessment. Neither that result nor the installed baseline binary verifies the new source changes or establishes that the dependencies are vulnerability-free.

Verification uses synthetic accounts, fake credential stores and local fixtures. No live Gmail or OpenAI account penetration test, private-network exploit, release installation or new dependency advisory scan is claimed. The older [31 October review](tern-daybreak-review-2026-10-31.md) remains a historical assessment with its original scope and line references.

## Secure defaults and accepted limits

- Keep remote message content blocked by default. Consent must pass through the prepared resource list and native destination policy.
- Require receiver authentication evidence before applying remembered sender permission; scope temporary permission to the current message identity.
- Persist removal intent before destructive work, retain failed stages and retry them before restoring or reauthorizing an account.
- Bound callback sockets, DNS waits, HTTP response headers, image bytes, request duration and concurrency.
- Keep credentials in Keychain and the Application Support directory restricted to its owner (`0700`). Never log tokens, message bodies or email addresses.

The [local data decision](../security-threat-model.md) retains plaintext SQLite caches under the signed sandboxed app and encrypted macOS volume boundary. Software with the same user's filesystem access, Full Disk Access or an unlocked backup can read the cache. This work adds neither application-level database encryption nor secure erasure; SQLite and full-text-search remnants remain within the accepted storage model. Files explicitly exported or opened outside the app follow their destination's protections.
