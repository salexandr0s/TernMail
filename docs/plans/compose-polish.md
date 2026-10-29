# Compose window polish

## Plan

1. Use a compact native toolbar with an icon-only Send action. Move formatting controls into a small optional bar, opened by an accessible Formatting button. Keep the link popover available when the bar is hidden and preserve editor selection and keyboard shortcuts.
2. Tighten address/subject rows and the From picker. Retain the native token-field focus ring. Remove the repeated Subject placeholder. Compact outgoing attachments and quoted text while preserving filenames, removal controls, warnings, and the 128-point minimum writing area.
3. Check new/reply compose windows, formatting/link commands, Cc/Bcc, attachments, quoted text, narrow sizes, and light/dark appearances using synthetic data. Run appropriate checks, review, commit, and update the handoff.

No send, draft, authentication, or persistence behavior changes are planned. The approved reader, list, and Settings layouts remain unchanged. The plan review found no blockers; selection preservation and the always-mounted link popover are the main functional checks.

The user then supplied Apple Mail as the preferred starting point. Follow its recipient-first ordering (To, optional Cc/Bcc, Subject, From), left-aligned labels, subtle row dividers, and trailing Send action. Keep Tern's supported formatting tools and compact native controls.

## Result

Implemented in `9ea9cc8`. The compose window uses a compact native toolbar with Formatting, Attach Files, Discard Draft, and a small blue Send icon at the trailing edge. The optional formatting bar groups text styles, lists, and links below the header. Its transition uses the existing reduced-motion-aware animation helper.

The header follows the Apple Mail reference. Labels align left, dividers separate rows, and padding is tighter. The Subject placeholder and a redundant link-editor hint were removed. The From selector uses a small native menu. Outgoing attachments occupy one horizontal strip, with full filenames available through help and accessibility. Quoted text uses smaller type and a 128-point maximum viewport. The writing area retains its 128-point minimum.

## Verification

- Final Debug build passed: `/tmp/tern-compose-polish-final-build.log`.
- Hosted app tests passed: 37 tests in 9 suites, `/tmp/tern-compose-polish-tests.log`. The later recipient-first ordering and trailing Send edits were rebuilt and inspected live.
- Core tests passed: 205 tests in 31 suites, `/tmp/tern-compose-polish-core-tests.log`. The package resolution file is unchanged after SwiftPM.
- New messages, replies, and forwards were inspected with synthetic data in light and dark appearances.
- A 480-point-wide dark window displayed expanded Cc/Bcc, formatting controls, and attachments without clipping. With all of those visible, the native minimum height grows to roughly 400 points to preserve the editor's minimum size.
- Recipient entry and Tab navigation worked. Cc/Bcc reveal focused the correct field. Bold preserved the selected body text; Cmd-K opened the link editor with the formatting bar hidden and linked the selected word.
- Three synthetic local attachments displayed in one row; horizontal overflow and removal worked. Forwarding retained its synthetic attachment, and reply/forward quote disclosure worked.
- Autosave status appeared. Send, discard, draft, account, and editor logic were unchanged. No real Gmail request or send was used.
- Read-only source review found no blockers. `git diff --check` passed; no TODO/FIXME was introduced.

Spoken VoiceOver, older macOS versions, and Release were not exercised in this pass. Accessibility labels and expanded/collapsed states were inspected. No work remains in this compose design pass.
