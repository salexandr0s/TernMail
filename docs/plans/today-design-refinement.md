# Today design refinement

The Today page should make outstanding work easy to scan, with the calendar at the upper right and events below it. The first implementation repeats status information and gives each item enough height to push follow-ups below the initial viewport.

## Layout and components

- Constrain the page width and keep To do, I owe, Follow-up emails, and Unread emails in one work column. Use a compact calendar and agenda rail at wide widths. At narrow widths, keep the calendar in an expandable section near the header and work in one continuous column.
- Give sections consistent headings and counts of displayed items. Put New Task in the task heading and fit account/list choices on one row when space permits.
- Make follow-up titles, people, source mail, urgency, and changes since the previous visit visible. Move routine schedule detail into an accessible disclosure. Keep primary actions visible.
- Use compact mail rows, day-grouped events, and consistent loading, empty, warning, and coverage components. Show brief data limitations inline, with full coverage details available through a native information control. Keep failures visible.
- Refine the snooze sheet, including presets, date/time selection, pending and error states.

## Behavior to preserve

Use existing model actions and account scopes. Preserve one vertical scroll container and visibility-based acknowledgement on each presented row. Keep meaningful change reasons visible so history cannot acknowledge information hidden by the redesign. Preserve keyboard controls, accessibility identifiers, native semantic colors and fonts, Increase Contrast, and Reduce Motion behavior.

## Verification

Build the app, run the existing Today model/projection/dashboard and native workflow tests, and inspect wide light and narrow dark renders. Review empty, loading, disconnected, partial-data, and error presentations. Check the generated token inventory after the component changes. No live provider calls or sending are needed for this design pass.
