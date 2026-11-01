# Email design pass

Date: 2026-11-01

## Findings and plan

The email workspace already has native controls, semantic colors, adjustable list density, and a compact compose window. This pass focuses on remaining crowding in the inbox and reader.

1. Give the reader subject its own row, with conversation actions at the trailing edge. Put labels below it so long subjects wrap independently of metadata.
2. Make quick filters adapt to the list width. Use labeled toggles when they fit and accessible icon toggles otherwise. Keep Clear visible whenever filters are active.
3. Reserve room for attachment and label counts in inbox rows. Show omitted-label counts with names on hover, and use an attachment count beside labels instead of squeezing in a filename. Keep filenames visible in rows without labels and available on hover in both layouts.
4. Separate received attachments from the message body with a divider and consistent spacing. Match Save All to the other small native controls.

Keep compose, mail actions, loading, selection, and keyboard shortcuts as they are. Retain the existing avatar alignment unless visual inspection shows a clear improvement.

## Verification

Build the Debug app, run existing list and layout tests, and inspect synthetic mail in light and dark appearances. Check narrow and wide readers, a long subject, labels, attachment metadata, and active-filter clearing. Use the existing design tokens and semantic styles. No new styling-only tests are planned.

## Outcome

All four changes are implemented. The existing avatar alignment and compose layout remain. The `--ui-audit-list` fixture now includes three user labels and a long attachment filename on the long-subject conversation.

- Debug builds passed, including the final fixture revision. Final build log: `/tmp/tern-email-design-final-build.log`.
- All 21 existing tests in `MessageListTests`, `ReadingPolicyTests`, and `SidebarLayoutTests` passed. Test log: `/tmp/tern-email-design-tests.log`. The later fixture edits run only with `--ui-audit-list`, which these tests do not enable.
- Native inspection covered light and dark appearances, standard and compact rows, 300- and 360-point lists, long subjects, wrapping reader labels, omitted-label counts, compact attachment counts, long filenames, and received attachment spacing. Toggling a filter and Clear updated the list correctly. Existing layout tests also cover 720-, 960-, and 1280-point workspace widths.
- Independent code review and `git diff --check` passed. No mail-model, persistence, or sending code changed.

Spoken VoiceOver, enlarged text, and multi-file Save All were not separately exercised. The installed Release app was not replaced, and nothing was pushed.
