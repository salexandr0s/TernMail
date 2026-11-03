# Calendar design pass

Completed for the user's calendar design request on 2026-10-30.

## Experience

- Navigation has two clear rows: the displayed date range, Today and New event above the view picker and search. Day and week headings include the year. Narrow calendar panes move the sidebar into a popover while retaining navigation, search and creation controls.
- The sidebar combines the mini-month, calendar visibility and the selected day's agenda in one scrolling surface. Calendar accounts, read-only calendars, event times and locations have distinct hierarchy.
- Day and week views align date headings, all-day events and timed columns. A minimum column width preserves readability beside the assistant. Today, weekends, current time and selected events have separate visual treatments.
- Month cells adapt their event capacity to the available height and provide a More action for overflow. Short windows scroll instead of clipping the calendar. Clicking an event selects both its day and event; double-clicking opens it.
- Year cards open their month from the heading and their day from the mini-calendar. Mini-month columns use equal measured widths.
- Event titles use semantic foreground colors on restrained calendar-color backgrounds. Times retain their full width, and truncated titles remain available through help and accessibility labels.
- Search rows separate date, title, location and time. Search has a focus ring, clear button and visible date-window status. Changing calendar visibility now refreshes an active search.
- Event editing, recurrence, calendar management, activity and import review share native form styling, clearer sections and persistent action footers. Settings use a full-width segmented control so both section labels remain legible. Import review shows selection counts and handles empty or unwritable destinations.

The work uses SwiftUI controls, macOS semantic colors and typography, and shared spacing and sizing in `Tokens.Calendar`. The sidebar no longer implies complete month availability through event dots when only the displayed day or week has loaded.

## Implementation

`CalendarView.swift` owns the adaptive shell and existing action routing. `CalendarSidebar.swift` contains the calendar list and agenda. `CalendarGridViews.swift` and `CalendarTimeGrid.swift` own the calendar surfaces. The editor, management, activity, recurrence and import files contain the supporting sheets.

The existing calendar models, Google client, operation queue, recurrence engine, permission boundaries and notification delivery are unchanged. Editor submission continues through the existing save callback, and import retains its existing operation sequence. The editor and import review disable conflicting controls while submitting.

## Verification

- Debug build passed using an isolated source snapshot, excluding concurrent assistant and attachment edits. The project was regenerated to register `CalendarSidebar.swift`.
- All 45 tests in six focused hosted suites passed: calendar layout, model, management, assistant tools, email integration and shortcut routing. Log: `/tmp/tern-calendar-design-tests.log`.
- All 66 focused Core tests in 14 suites passed. Log: `/tmp/tern-calendar-design-core-tests.log`. SwiftPM restored the package-only lockfile after Xcode validation.
- Native synthetic previews covered light and dark appearance, week/month/year presentation, event selection and editing, event creation, search focus and clearing, calendar-visibility search refresh, settings sections, and compact layouts with the assistant open. A 960-point-wide short window retained header controls and scrolled month content. The compact calendar popover retained calendar selection and settings access.
- Native inspection found and corrected horizontal dividers inside event surfaces, truncated month-event times, compressed settings labels and uneven year-grid columns. These presentation fixes were followed by a Debug build and visual inspection.
- Independent review checked event actions, permission handling, recurrence selection and import behavior. Its partial-month dot and current-day background findings were corrected.

Native previews use synthetic calendars and in-memory writes. Their fixture search does not implement text matching, so it verifies search presentation and visibility refresh only. Live Google authorization/writes, notification delivery, spoken VoiceOver and older macOS versions were not rechecked during this design pass. See the [provider and system acceptance gaps](../milestone-5-verification.md#provider-and-system-acceptance).
