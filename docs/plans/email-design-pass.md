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

## Email item follow-up

The user supplied a screenshot and requested a pass on the email rows, with colorful, distinguishable tags. The plan was to color the whole badge, align avatars with senders, and make previews quieter while retaining the existing metadata counts.

`MessageListRow.swift` now aligns the avatar and unread dot with the sender line, uses medium weight for read senders, reduces preview text to the caption style, and adds space above metadata. Mail badges use compact rounded rectangles with opaque fills and contrasting text. Saved Gmail backgrounds are retained. `LabelAppearance.swift` assigns fixed colors to categories and stable palette colors to other uncolored labels; these fallbacks are local and do not change Gmail. Custom icons remain visible, while the generic tag icon is omitted to save room.

The Debug build passed (`/tmp/tern-email-items-build.log`), and all 16 existing tests in `MessageListTests` and `LabelAppearanceTests` passed (`/tmp/tern-email-items-tests.log`). Independent code review and `git diff --check` passed. Native inspection used a 300-point list in a roughly 1000-point window: dark standard rows at 100% text and light compact rows at 150%. Read, unread, selected, long-label, omitted-label, and attachment-count rows remained legible without overlap. Full label names remain in accessibility summaries and hover help. Spoken VoiceOver and Increase Contrast were not separately exercised. No mail-state code changed, no styling-only tests were added, and the installed Release app was not replaced.
