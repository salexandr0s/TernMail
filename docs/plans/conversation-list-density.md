# Compact conversation list

## Plan

1. Reduce the list to three compact lines: sender and status, subject, preview. Replace the avatar with an unread gutter, use one preview line, and move the account identity into a small header badge. Preserve full account names in help and accessibility text.
2. Keep native selection, context menus, keyboard navigation, and row separators. Snoozed rows use the preview line for their return time. Use existing spacing and semantic text/color tokens; leave the approved reader and Settings layouts alone.
3. Inspect normal, selected, unread, starred, multi-account, and narrow-list states in light/dark appearance. Run the applicable build/checks, record results, and commit.

The user-provided screenshots establish the density problem. Implementation uses Tern's existing native list and independent layout decisions; no competitor code or assets are used.

## Acceptance

- Normal mixed-account rows should be about 60 points tall, substantially shorter than the current roughly 95-point rows.
- Sender, subject, preview, and essential statuses remain legible at the 300-point minimum list width.
- Account badges use short initials with full-address help. Identical initials receive a disambiguating suffix.
- Full row accessibility names and all existing list operations remain available.

## Result

Implemented in `c1832c0`. Normal mixed-account rows are approximately 64 points tall, down from roughly 95 points in the supplied screenshot. This provides about 50% more rows in the same height. Text sizes are unchanged. Empty previews do not reserve a line.

The unread dot has a reserved gutter and changes to the selection foreground when selected. Account badges reuse the sidebar's account colors while keeping neutral backgrounds and semantic text colors. Initials are derived from all connected accounts, with separated suffixes for collisions (for example, `A·1` and `A·2`). Full addresses remain in help and row accessibility names. Snooze return times replace the preview line.

`--ui-audit-list` adds synthetic conversations with long names/subjects, empty subjects/previews, and mixed read/star states. It is Debug-only and uses no live Gmail data.

## Verification

- Final Debug build passed: `/tmp/tern-list-density-final-build.log`.
- Hosted app tests passed: 37 tests in 9 suites, `/tmp/tern-list-density-tests.log`. The final empty-preview and badge-suffix presentation edits were subsequently rebuilt and inspected.
- Core tests passed: 205 tests in 31 suites, `/tmp/tern-list-density-core-final.log`. The package resolution file is unchanged.
- Live light/dark checks at the 300-point list width covered full lists, long senders/subjects, blank subjects/previews, starred/unread rows, and account badges.
- Keyboard search focus, Escape back to the list, arrow-key movement, and Shift-arrow multi-selection worked. Selected unread dots and badge text stayed visible.
- Context menus and snoozing synthetic mail worked; the Snoozed list showed the compact return-time row.
- Read-only review found one badge-suffix collision edge; adding the separator resolved it. No other source findings remained.
- `git diff --check` passed. No new tests were added for styling, and no model or network behavior changed.

Spoken VoiceOver, older macOS versions, and every possible locale/date string were not exercised. Existing reader and Settings layouts are unchanged. No work remains in this pass.
