# Account writing styles

## Requested behavior

When ChatGPT is connected and assistant access is enabled for a mail account, learn how that account writes from its latest 100 sent messages. Use the account's learned preferences when preparing outgoing replies. Keep work and personal accounts separate, and follow an explicit tone request ahead of learned preferences.

## Implementation plan

1. Add bounded, read-only sent-message retrieval to SyncEngine. Inspect up to 100 unique SENT messages, remove quoted exchanges and common signatures, and retain only bounded authored-text excerpts in memory. Report sample counts and incomplete coverage. Do not mark messages read or download ordinary attachments.
2. Analyze each account separately through the existing ChatGPT provider. Request a strict, versioned profile containing only enumerated writing traits and language/register preferences. Reject malformed output and avoid producing a profile when evidence is insufficient.
3. Coordinate initialization in a separate app model. Start after connection, model discovery, and account permission are ready. Cancel stale work when access or mailbox identity changes. Store only validated profiles locally; erase them when learning or account access is disabled. Provide status and a relearn action.
4. Apply only the sending account's profile to drafts. Snapshot its revision for each model response, and reject a draft composed before a newly available profile was supplied. Wait at most ten seconds for initial learning per account and request; a timeout creates no draft. Off, failed, and insufficient profiles allow a context-based draft with a visible note. Recheck the style decision before committing the draft. Learned style must not alter the assistant's chat voice, supply facts, grant permissions, or override the user.
5. Add settings controls, update privacy/help text, and verify retrieval boundaries, profile validation, lifecycle isolation, draft integration, and native layout. Preserve concurrent calendar and attachment work.

## Bounds and data handling

- Inspect no more than 100 unique sent-message IDs across at most five listing pages; fetch full messages in batches of ten.
- Limit individual excerpts to 2 KiB and the complete model input to 80 KiB. Bound MIME text-part loading separately.
- Require at least five usable samples and enough authored text before learning a profile. Show the actual number used; fewer than 100 available messages is valid.
- Treat all excerpts as untrusted data. Analysis has no tools. Store no excerpts, message IDs, contacts, quotations, or free-form model instructions in the profile.
- Keep profiles separate by mail-account identity. ChatGPT disconnection cancels learning; removing mail access or turning off learning deletes that account's local profile.

Gmail's [message-list API](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list) supports SENT filtering and pagination but documents no ordering parameter. Retrieval follows the sent listing and sorts the selected messages by their returned internal date. This limitation should remain explicit in implementation documentation.

## Verification

Focused tests should catch cross-account profile use, publication after revocation, malformed model output, retained raw content, quoted-text contamination, pagination errors, and changed draft retry semantics. Run the affected Core and hosted app suites, build the app, and inspect the settings in an isolated preview. Real mailbox contents must not be used for development fixtures.

## Status

Implemented with separate Core retrieval, profile analysis, app lifecycle, and settings components. Profiles initialize after model discovery and mail permission, including app startup. Account removal also clears profiles when the assistant has never been opened. Profile-file errors do not interrupt the rest of account cleanup.

Verification on 2026-10-30:

- Debug build passed. The combined hosted app suite passed 154 tests in 28 suites. After the final draft-gate refinement and wiring regressions, 32 focused hosted tests in three suites passed.
- All 23 focused Core tests passed, covering bounded reads, pagination, quote/signature removal, HTML list markers, strict profiles, cancellation, and byte limits. The final result is recorded in `/tmp/tern-writing-style-final-core-tests.log`; SwiftPM ran after Xcode and restored the package-only lockfile.
- Independent code review found no remaining blocker. The final regressions cover stale profile text before the gate and during the engine read, committed draft replay, visible fallback notes, automatic initialization, and account-scoped prompt context.
- Native settings and live ChatGPT learning passed after the user unlocked the Mac and approved Keychain access. Both synthetic accounts learned from 100 sent messages. The informal English examples produced an “Informal · Brief · Direct” profile; the formal German examples produced “Formal · Brief · Direct”. Settings showed separate account switches, Relearn controls, sample counts, and update dates.
- Live draft review confirmed the correct sender and different registers: the first account used “Hey River” and a short conversational reply; the second used “Dear Sky” and “Kind regards”. Both incoming threads were in English, and both drafts retained that language. Drafts opened in Tern's composer and remained unsent. No real mail was used or sent.
- The final live priority suggestion also completed with formatted text and validated email cards. A separate mail-layout regression is tracked in `assistant-design.md`; it does not invalidate the observed learning and draft results.

Build and hosted logs: `/tmp/tern-writing-style-build.log`, `/tmp/tern-writing-style-app-tests.log`, and `/tmp/tern-writing-style-final-tests.log`. The follow-up build passed in `/tmp/tern-assistant-final-live-build.log`. The live check used `/tmp/tern-writing-style-build/Build/Products/Debug/Tern.app` with `--ui-audit --ui-audit-live-chatgpt --ui-audit-writing-style --ui-audit-list --ui-audit-dark`. This derived-data directory is now also being used by the layout-fix chat; inspect its current build before relying on the artifact.
