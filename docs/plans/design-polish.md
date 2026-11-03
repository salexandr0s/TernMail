# Tern design improvement

## Scope

Improve all existing user-facing surfaces in the native macOS app. The base is milestone 4 at `410baaf`, which contains the completed milestone 3 interface. Work lives on `codex/tern-design-polish` in a separate managed worktree. This pass does not implement planned milestone 4 or 5 features.

## Direction

Keep Tern recognizably native: semantic macOS colors and type, clear selection, comfortable density, restrained accent color, consistent SF Symbols, and quiet rounded surfaces. Labels, recipients, account identities, attachments, and status messages should share a consistent visual vocabulary. Motion should explain state changes in 120–220 ms and respect Reduce Motion.

## Work phases

1. Audit every visible surface and establish shared tokens and components. Check the baseline build and review the plan.
2. Polish navigation and mail reading: sidebar, thread list, toolbar, conversation, and received attachments.
3. Polish composing and sending: compose window, recipient tokens, attachment strip, outbox, and shortcuts reference.
4. Polish supporting surfaces: sign-in, settings, label editor, label picker, and snooze picker.
5. Integrate the window shell, feedback notices, empty and loading states. Review all changes, build Debug and Release, run the relevant existing tests, and inspect the app using synthetic mail in light and dark appearances.

Parallel implementation has disjoint file ownership. The lead owns shared integration, validation, and handoff; workers own the foundation and bounded surface groups. Build commands run serially to avoid competing Xcode operations.

## Acceptance

- Every existing screen and shared component is audited; changes or reasons to retain native behavior are recorded.
- Existing mail, compose, label, search, snooze, and account actions keep their behavior.
- Text wraps or truncates intentionally with full text available where necessary; windows remain usable at supported narrow sizes.
- Keyboard focus, native menu behavior, accessible names, disabled states, and Reduce Motion remain supported.
- Light and dark appearances have readable text and controls; status is never communicated only by color.
- Existing tests and app builds pass, with any environmental or pre-existing gaps reported.
- Changes are committed and the handoff records the exact launch command and remaining limitations.

## Result

Implemented on 2026-10-29. The user reviewed the live app and confirmed the final density: 8-point reader margins, 6-point card padding, 6-point gaps, and Inbox inline with the subject. Message controls retain their larger click targets. The message document no longer adds a second layer of padding.

| Surface | Result |
|---|---|
| Window and navigation | Semantic backgrounds, shared sizing, clearer account sections and sync status. At narrow widths, reply actions share a menu so search remains visible. |
| Conversation list and search | Sender initials, unread marks, message counts, clearer text hierarchy, full snooze dates, and grouped empty-state actions. |
| Conversation reader | Compact cards, inline labels, wrapping attachments, clear sender actions, expansion transitions, missing/error states with retry, and HTML dark mode. |
| Composer | Clear header and Send action, restored recipient focus ring, subject focus indicator, attachment chips, quoted-text disclosure, and a protected minimum editing area. |
| Outbox and notices | Named delivery states, clear recovery actions, wrapping feedback, and accessible Undo/dismiss controls. |
| Settings and sign-in | Grouped settings, account identity, actionable empty states, existing app artwork, and plain sign-in availability copy. |
| Label and snooze sheets | Consistent headings and footers, readable selections, larger color targets, and layouts that fit shorter windows. |
| Keyboard reference | Grouped commands with consistent keycaps and scrolling. |
| Shared components | Semantic badges, avatars, surfaces, empty states, and motion that respects Reduce Motion. Selected-row avatars and badges retain contrast. |
| Native controls retained | NSTextView editing, recipient token behavior, standard menus, keyboard commands, account color model, Quick Look, and system open/save/confirmation panels. |

Code review covered all changed surfaces. Live checks used the in-memory `--ui-audit` mailbox: light/dark reading, collapse/expand, selected rows, the 960-point main window, compact reply menu and search focus, composing with Cc/Bcc and recipient focus, settings, label creation, the snooze calendar, search empty states, and attachment Quick Look. The user approved the final light preview.

See the [development guide](../development.md) for build and launch instructions. Live Google services, macOS 14/15 rendering, spoken VoiceOver output, and OS-level Reduce Motion/Increase Contrast settings were not exercised. Those accessibility paths were reviewed in source; the audit flags can check app appearance without changing system preferences. Complex HTML backgrounds and non-RGB colors retain the existing dark-mode adapter's limits.
