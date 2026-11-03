# Milestone 5 verification

Implementation and acceptance are tracked separately. The scope is the 72 items in [the execution checklist](plans/milestone-5-execution.md). Work is integrated on `main`. The 2026-10-30 consolidation also includes the completed settings, Calendar and Assistant follow-ups.

## Integration checkpoints

Milestone 4 completed before Milestone 5 implementation: 398 Core tests in 63 suites, 193 hosted tests in 34 suites, a universal Release build, and native synthetic checks for compose identities and Settings. Logs: `/tmp/tern-m4-full-core-final.log`, `/tmp/tern-m4-hosted-verified.log`, `/tmp/tern-m4-release.log`.

Milestone 5 Core passes **471 tests in 82 suites** (`/tmp/tern-m5-core-final.log`). The full hosted suite passes **242 tests in 44 suites** in both the shared checkout (`/tmp/tern-m5-hosted-complete.log`) and the frozen source snapshot (`/tmp/tern-m5-frozen-hosted.log`). Source revision: `8457537`. The verification used an isolated temporary source snapshot.

The milestone's universal **Release build passed for arm64 and x86_64**, and strict code-signature verification passed (`/tmp/tern-m5-frozen-release.log`). Its former `build/Milestone5/Tern.app` bundle was removed during consolidation. The installed `~/Applications/Tern.app` includes the subsequent settings redesign and Calendar/Assistant changes; `build/Tern-build-info.json` records its source revision and executable hash. The combined build passed 265 hosted tests, 471 Core tests and universal Release verification.

Review found and corrected timestamp precision in Snooze Undo, read timing for inactive readers, account/message boundaries in detached actions and URL routing, draft attachment ownership, contact expansion after permission changes, and cache eviction of active snoozes and newer organizer invitations. Final workflow review connected missing Send Again, category navigation and action-sound hooks. Links now route Spam/Trash correctly and open a conversation window with validated account/message scope, independent of list filtering, pagination or a hidden reader. The hosted regressions pass.

## Native checks

The native audit app uses synthetic mail, temporary outgoing/download folders, isolated account preferences and a separate bundle identifier. It must not change a signed-in account, deliver mail, change the default mail handler or request system permissions as part of this audit. Observed native checks covered dark-mode startup, the combined-account list, quick-filter controls, the View menu, the customization palette and General Settings navigation. Hosted AppKit layout checks covered 960/1,280-point widths, toolbar styles, Mail/Library/Calendar transitions, and exact category selection in single/combined account layouts. Earlier native Milestone 4 compose/Connections checks and the separately committed event-card light/dark/narrow checks are documented in [Milestone 4](plans/milestone-4.md) and [Events in mail threads](plans/thread-events-design.md).

Native menu captions can populate lazily in the customization palette. The native menus remain in place; this was not established as a functional menu failure. Broader native workflows were not completed while the UI tool reported concurrent window changes. No live provider or system-permission result is inferred from these checks.

## Provider and system acceptance

These checks require the owner's configured account or system settings and have not been established by synthetic tests:

- Gmail IMAP IDLE through account consent, network loss/recovery and real new-mail arrival; actual Gmail link routing, masked attachment-part responses, settings writes, permanent deletion, MIME delivery and RSVP round trips.
- People API photo/group reads with the API enabled and Contacts granted; unsupported photo hosts, redirects and incomplete groups retain the documented fallback.
- Notification authorization and native delivery/actions, Focus activation, default-mail-app assignment, AppleScript client permissions and system Writing Tools availability.
- Connected Google Calendar agenda, availability and writes under F15's independent permissions. EventKit is superseded.
- Spoken VoiceOver, increased contrast, and macOS versions other than the local test system.

Live destructive writes and outgoing mail were not used to verify implementation. These remain acceptance gaps.
