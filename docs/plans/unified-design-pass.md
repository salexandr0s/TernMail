# Unified Tern design pass

Date: 2026-10-30. Workspace: `REA_Mime`, branch: `codex/tern-unified`.

The user requested a full component and interaction pass after consolidation, followed by a commit. This pass preserves the native macOS design, semantic colors, shared spacing and motion tokens, and the completed B5b wiring.

## Plan

1. Inspect every visible component and its loading, empty, error, selection and focus states. Divide compose, reader/status, popups and settings/commands between independent owners; keep shared layout and integration with the lead.
2. Fix concrete interaction defects, review each bounded change, and retain existing components that already behave consistently.
3. Run the hosted app suite, universal Release build and Core suite; check the synthetic app in native windows; record evidence and remaining live-service limits before committing.

## Component coverage

| Area | Components | Findings and treatment |
|---|---|---|
| Shared design | Tokens, surfaces, badges, avatars, popup primitives | Semantic colors/type, shared spacing and reduced-motion helpers retained. Let empty-state text fit its available height so narrow Outbox windows cannot stretch all three columns beyond the window. |
| Mailbox | Main split view, sidebar, sync footer, split handles, thread list, toolbar, search | Preserve continuous sidebar footer, native selection and stable list layout. Align single-key reply availability with toolbar/menu. Add custom-label chips to conversations, including search and Snoozed, with bounded overflow and full accessible names. |
| Compose | Header, recipients, sender selector/photos, rich editor, formatting/link popup, attachments, quote, status, toolbar | Prefill and edit/remove existing links at a caret; reveal draft-load errors; expose account/file-copy progress; enlarge actual Cc/Bcc hit areas. |
| Reader | Conversation header, badges, message headers/actions, HTML/text body, received attachments | Fill the reader pane with message cards as requested, retaining the outer margins. Show retry for failed body loads; prevent cancelled rendering from publishing stale output; disable attachment actions during download. Preserve remote-content isolation. |
| Outgoing/status | Outbox rows, empty state, progress, undo/error notices | Keep Outbox List mounted when empty; clear stale selection; route search dismissal back to its list and preserve native Return handling; pause toast dismissal while an action has keyboard focus. |
| Popups | Label filter/checklist, move, label editor, color/icon palettes, snooze date/time | Pointer selection followed by Down/Return retains filter focus. Bound long parent-label names and expose full names on hover. Existing keyboard/Escape behavior and reduced-motion states retained. |
| Settings/auth | General, accounts, account appearance, sign-in/reauth screens | Apply configured-auth guards to every exposed sign-in action. Existing native form and scroll layout retained. |
| Commands | Menu bar, shortcut help, single-key monitor | Reproduced message commands targeting a hidden mailbox with Settings front. Use scene focus for mailbox actions and account confirmations, preserving global New Message/Check Mail. |

## Validation

The design changes were tested in a temporary source snapshot containing only this commit's app and Core changes. Another chat was implementing the assistant in the canonical checkout at the same time; those changes remain outside this commit. Every staged source and test file was compared byte for byte with the tested snapshot.

- Hosted Debug suite: 49 tests in 14 suites passed, including caret link editing/Undo, failed body load/retry/cancellation, and the extended native sidebar selection/layout regression. Log: `/tmp/tern-design-verified-app-tests.log`.
- Universal Release build passed; the binary contains arm64 and x86_64. Log: `/tmp/tern-design-verified-release.log`.
- Core suite: 236 tests in 37 suites passed, including batched tag membership, pending label edits, account collisions, hidden drafts and Spam/Trash coverage. Log: `/tmp/tern-design-verified-core-tests.log`.
- Native synthetic preview: checked dark wide and light compact windows, full-width reader cards, tag chips, immediate label application in Inbox, labels in local search, continuous sidebar/footer, Outbox filling and draining, compose recipient validation, Cc focus, sender switching, link prefilling/removal, message commands with Settings or WebKit focused, and shortcut help.
- Read-only implementation review approved all scoped changes. Whitespace checks passed.

The Outbox regression exposed a real minimum-size negotiation issue. The window and root host stayed 960×666 while the split view grew to 960×1058. Removing the empty-state message's forced vertical size kept the split at 960×666 on every transition. The extended regression passes with all original geometry assertions intact.

This was an offline audit with synthetic mail. Live Google/OAuth, older macOS versions, spoken VoiceOver, and attachment downloads against Gmail were not exercised. The final one-line empty-state sizing change was covered by the native hosted regression; the live narrow-window check preceded that final change. Existing AppIntents, sandbox/WebKit and test fixture warnings remain. No assistant feature or milestone scope was added to this design commit.
