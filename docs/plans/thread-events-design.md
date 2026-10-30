# Events in mail threads

The reader puts the conversation subject first, then a compact event group, an AI summary card, and the messages. Events and the summary share a translucent fill and subtle border, distinct from the solid message cards. Reduce Transparency uses an opaque surface; Increased Contrast strengthens the border. See [Conversation summaries](../chatgpt-assistant.md#conversation-summaries) for generation, access, sources, and cache behavior.

## Event group

Use a single rounded surface with no section heading. A normal event row is about 48 points tall, with a 32-point month/day tile, title and date/time line. The title occupies one line, with the full title available on hover and in details. Warnings and longer date ranges may increase the row height.

Show two events initially. Current invitations and corrections take priority over superseded invitations. More events remain available through an explicit expansion control. A small badge overlays the date’s upper-right corner: a tick for a saved event or explicit acceptance, a question for a proposal or uncertainty, and a cross for a cancellation or decline. Updates and superseded invitations have distinct arrow/clock symbols. Color reinforces the symbol; tooltip and accessibility text give its meaning. Clicking the date opens the explanation and supporting details.

## Actions and details

One primary action opens the saved event, reviews a proposed change, or responds to an invitation. A response still goes through the existing review flow. Adding a personal copy remains separate from accepting an invitation.

The event menu contains details, dismissal, and secondary actions. Expanded details show the location and supporting email excerpt where available. Invitation evidence is a location, so it must not be presented as a quoted email excerpt. Cancelled and superseded invitations do not offer RSVP.

## Dates and layout

Use Tern's selected time zone consistently for the tile and date/time line. Include the year, and show time ranges when known. Date-only all-day events retain their calendar date; show the final included day instead of the exclusive end supplied by calendar data. Undated suggestions use a neutral calendar symbol.

Primary action and menu sit side by side. At narrow reader widths, all actions remain available in the menu so the row stays compact. Keep native keyboard focus, semantic text styles, and system colors. The reader separates the event and summary cards by 16 points; messages within the conversation remain closely grouped.

## Compact card verification

- The final production-source Debug build passed after removing temporary preview fixtures. Log: `/tmp/tern-header-compact-production-build.log`.
- A standard event row now measures 48 points, with a 32-point date tile. The section heading and inline review-status text are gone. Status badges preserve the explanation in help, accessibility labels, and disclosed details.
- All 20 tests in `EmailCalendarTests`, `CalendarLayoutTests`, and `InvitationBannerTests` passed. Two added regressions cover badge precedence and prevent mixed or declined attendee responses from displaying an acceptance tick. Log: `/tmp/tern-header-compact-tests.log`.
- Native synthetic checks covered the full reader in light/dark appearance, the reader beside the assistant, a 288-point event card, accepted/declined badges, date-tile disclosure, action menus, and summary expansion. Inspection caught a date-tile hit-target gap; the entire tile now opens details. Independent review found no remaining blockers.
- Screenshots: `tern-compact-header-light.png` and `tern-compact-header-dark.png` in `/Users/developer/.codex/visualizations/2026/10/30/01a18c3d-16cf-72f2-be86-90dd36323a55/`. The preview uses synthetic mail and a synthetic summary provider. Spoken VoiceOver and system Reduce Transparency/Increased Contrast settings were not exercised; their source-level fallbacks were reviewed.

## Original design verification

- Debug build passed. All 14 tests in `EmailCalendarTests` and `CalendarLayoutTests` passed, including four presentation regressions for date-only ranges, time-zone rollover, empty calendar locales, and event ordering. Log: `/tmp/tern-event-design-tests-final.log`.
- Native synthetic checks covered light/dark appearance, 288-point card width, long titles, unknown dates, multi-day all-day ranges, current cancellation versus superseded invitation, primary Review and Respond callbacks, keyboard response-menu activation, source disclosure, dismissal, and expansion from two to five events.
- The full mail reader displayed a locally detected event above its messages, retained the card when the assistant opened, and restored the reader width when it closed. A summary layout study ran only in the temporary fixture; generated summaries are not part of this implementation.
- Native inspection found an empty calendar-locale identifier rendering month names as M11. Formatting now falls back to the user's locale for both nil and empty identifiers, with regression coverage. Independent code review found no remaining blockers.
- Verification ran in `/tmp/tern-event-design-wkpgkrpo`. The four changed production source/test files match that copy byte-for-byte. Debug-only preview fixtures exist only in that disposable copy. The preview bundle is `TernEventDesign.app`, ID `dev.tern.events.design`; use `--ui-audit --ui-audit-found-events --ui-audit-light` for the full reader or `--ui-audit --ui-audit-event-cards` for component scenarios.
- Live Google writes and RSVP delivery, spoken VoiceOver, increased-contrast settings, and older macOS versions were not exercised. The existing calendar acceptance gaps remain in `SESSION_HANDOFF.md`.
