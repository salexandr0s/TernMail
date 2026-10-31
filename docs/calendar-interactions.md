# Calendar interactions

Tern supports the everyday event workflows below. The interaction reference was Google's documentation for [creating events](https://support.google.com/calendar/answer/72143?hl=en), [editing repeating events](https://support.google.com/calendar/answer/37115?hl=en), and [calendar keyboard shortcuts](https://support.google.com/calendar/answer/37034?hl=en).

## Working on the calendar

| Action | How it works |
| --- | --- |
| Create a timed event | Click an empty time, or drag through a time range in Day or Week. Dragging upward also works. The editor opens with the selected dates and times. |
| Create an all-day event | Click or drag across the all-day lane or empty Month cells. A selection can cross a week row. |
| Move an event | Drag its body to another time or day. The point you grabbed stays attached to the pointer; timed events retain their duration. |
| Resize | Select an event and drag its start or end handle. All-day events have first-day and last-day handles. |
| Convert all-day/timed | Drag between the all-day lane and the time grid. An all-day event dropped into the grid becomes a one-hour event; a timed event dropped into the all-day lane covers its occupied days. |
| Preview or cancel | The proposed range appears while dragging. Times snap to 15 minutes. Escape or release outside the calendar cancels. Holding near the scrolling area's edge scrolls the calendar. |
| Edit details | Double-click an event, press Return with an event selected, or use Open Event in its context menu. |
| Duplicate/delete | Use the event context menu in the grid, Schedule, or search results. Delete also works from the keyboard. Read-only events can be opened and duplicated. Share sends the occurrence as an .ics file, as dragging a Schedule, agenda, or search row out does. |
| Undo | Command-Z reverses supported calendar changes. Guest notifications are reviewed when required. |
| Browse | Day, Week, Month, Year, and Schedule views; Today; previous/next period; a date picker; and a mini-calendar. The view switcher, Today, and the period arrows sit in the window toolbar. Schedule lists the chosen month's events by day. |
| Search | Search visible calendars and open, duplicate, or delete a result. |

Canvas shortcuts are D/1 (Day), W/2 (Week), M/3 (Month), Y/4 (Year), A/5 (Schedule), C (create), T (today), G (go to date), and / (search). They apply while the calendar canvas owns keyboard focus and single-key shortcuts are on in Settings, the same setting Mail uses. Arrow keys work without that setting: Up and Down move between the day's events, Left and Right step by a day in Day and Week or by a week in Month, and Option-Left and Option-Right change the period. The Calendar menu has Today (Command-T), Go to Date (Shift-Command-T), and the views (Control-Command-1 through 5). New Event is Option-Command-N, and Command-Z undoes.

## Saving and sync

A simple personal event saves when a drag ends. A repeating event or an event with guests opens the editor so the user can choose the recurrence scope and review guest updates. The editor already supports all-day dates, time zones, repeat rules, location, notes, links, guests, Google Meet, reminders, availability, and visibility.

Changes go through the durable calendar action queue. Pending individual creations, moves, resizes, and deletions appear immediately while offline. Pending events cannot be changed again until the earlier write is resolved. Failed or conflicting writes show the cached provider event and a Calendar activity message. A gesture also checks that the source event and calendar access have not changed since the drag began.

Queued series-wide operations are marked pending without locally inventing Google's recurrence expansion. Their final expanded dates appear after sync. All-day boundaries use calendar days, including daylight-saving transitions; timed moves preserve elapsed duration.

Calendar creation, sharing, colors, calendar selection, invitations from email, ICS import/export, printing, and notifications continue to use the existing implementation. Specialized Google products such as appointment booking pages, Workspace room booking, Tasks, and working-location events are separate from this event-interaction work. Redo, dragging beyond the displayed date range, and per-event color editing are not provided by this change.

## Verification

Focused tests exercise date selection, both resize edges, midnight and DST boundaries, moves from multi-day continuation segments, date-kind conversion, unchanged metadata, month hit-testing, source freshness, read-only behavior, recurring/guest review, offline projections, conflicts, duplication, and undo. The existing calendar model, layout, management, and sync-engine suites run alongside them.

On 30 October 2026, the integrated Debug app build and 40 hosted calendar tests passed. Another 21 core tests passed across the calendar sync, recurrence partition, and availability suites. Logs are `/tmp/tern-calendar-interactions-tests.log` and `/tmp/tern-calendar-core-tests.log`.

Native checks passed for timed drag creation and save, moving an existing event across both date and time, both timed resize handles, both all-day resize handles, all-day range creation, conversion in both directions, a backward month selection across rows, moving a continuation segment, release outside the calendar, recurrence scope review, guest notification review, read-only details, undo from the menu and keyboard, and Schedule date navigation. The active QWERTZ keyboard layout requires the automation's `super+y` input to produce Command-Z. Escape during a held drag and sustained edge autoscrolling were reviewed in code but not exercised by the native automation.

Native interaction checks use `--ui-audit --ui-audit-calendar`, which supplies synthetic calendars and events through an in-memory service. It does not access a Google account. Real Google round trips and notification delivery require a connected account and are separate from these checks.

The running review app is `/tmp/Tern Calendar Drag Preview.app` (bundle ID `dev.tern.calendar.drag.preview`). Its events are disposable and do not persist after quitting.
