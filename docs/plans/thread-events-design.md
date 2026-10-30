# Events in mail threads

The reader puts the conversation subject first, then a compact event group, then the messages. A future generated summary belongs between the event group and the messages. Until summary content exists, that position adds no placeholder or empty card.

## Event group

Use a single rounded surface with a subtle border. Each event has a small month/day tile, its title, and a date/time line. The tile helps readers scan for the day; the title says what the event is. Titles wrap, with the full title available on hover. Keep the heading quieter than the conversation subject.

Show two events initially. Current invitations and corrections take priority over superseded invitations. More events remain available through an explicit expansion control. Cancellations, updates, ambiguous matches, and missing dates remain visible without opening details. Additional uncertainty has a short visible cue and its explanation in details.

## Actions and details

One primary action opens the saved event, reviews a proposed change, or responds to an invitation. A response still goes through the existing review flow. Adding a personal copy remains separate from accepting an invitation.

The event menu contains details, dismissal, and secondary actions. Expanded details show the location and supporting email excerpt where available. Invitation evidence is a location, so it must not be presented as a quoted email excerpt. Cancelled and superseded invitations do not offer RSVP.

## Dates and layout

Use Tern's selected time zone consistently for the tile and date/time line. Include the year, and show time ranges when known. Date-only all-day events retain their calendar date; show the final included day instead of the exclusive end supplied by calendar data. Undated suggestions use a neutral calendar symbol.

At narrow reader widths, actions move below the title and metadata. Keep native keyboard focus, semantic text styles, and system colors. The reader separates the event group from the messages by 16 points; messages within the conversation remain closely grouped.

## Verification

- Debug build passed. All 14 tests in `EmailCalendarTests` and `CalendarLayoutTests` passed, including four presentation regressions for date-only ranges, time-zone rollover, empty calendar locales, and event ordering. Log: `/tmp/tern-event-design-tests-final.log`.
- Native synthetic checks covered light/dark appearance, 288-point card width, long titles, unknown dates, multi-day all-day ranges, current cancellation versus superseded invitation, primary Review and Respond callbacks, keyboard response-menu activation, source disclosure, dismissal, and expansion from two to five events.
- The full mail reader displayed a locally detected event above its messages, retained the card when the assistant opened, and restored the reader width when it closed. A summary layout study ran only in the temporary fixture; generated summaries are not part of this implementation.
- Native inspection found an empty calendar-locale identifier rendering month names as M11. Formatting now falls back to the user's locale for both nil and empty identifiers, with regression coverage. Independent code review found no remaining blockers.
- Verification ran in `/tmp/tern-event-design-wkpgkrpo`. The four changed production source/test files match that copy byte-for-byte. Debug-only preview fixtures exist only in that disposable copy. The preview bundle is `TernEventDesign.app`, ID `dev.tern.events.design`; use `--ui-audit --ui-audit-found-events --ui-audit-light` for the full reader or `--ui-audit --ui-audit-event-cards` for component scenarios.
- Live Google writes and RSVP delivery, spoken VoiceOver, increased-contrast settings, and older macOS versions were not exercised. The existing calendar acceptance gaps remain in `SESSION_HANDOFF.md`.
