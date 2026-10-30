# Settings design

Settings uses native macOS controls in a searchable sidebar window. Its default size is 800×620 points, with a 208-point sidebar and a 740×500 minimum. Shared rows use 8-point vertical padding; switches and buttons keep their natural widths. Groups fit their controls, and longer pages scroll.

Editors use the shared `SettingsEditorSheet`: 480 points wide for profiles and 560 for filters, Calendar settings and Assistant settings. Short forms fit their contents. Longer forms cap the scrolling area at 440 points, with validation and actions outside it. Profile schedules retain their existing modes and validation.

## Coverage

All 15 categories were reviewed in source and inspected in the native offline preview on 2026-10-30.

| Page | Checked layout |
| --- | --- |
| General | General and Mail Actions tabs; shortcut reference window |
| Accounts | Connections, Preferences, color palette, account and profile menus |
| Profiles | Empty list, account summary and compact New Profile sheet |
| Notifications | Permission row, account rules, sound and action controls |
| Reading | Appearance, conversations and privacy controls |
| Message List | Density, selection, two-column swipe controls, sidebar options and expanded categories |
| Composing | Writing, Templates, Signatures, Suggestions, signature defaults and link popover |
| Gmail Signatures | Populated primary signature, long alias address and read-only notice |
| Filters | Populated rows, edit sheet, long forwarding address, scrolling and fixed actions |
| Blocked Senders | Single sender with a group that fits its row |
| Vacation Responder | Populated message, organization option, dates, fixed Save and link popover |
| Attachments | Native opening-location menu and helper text |
| Assistant | Connection control, account access, writing style and privacy |
| Failed Changes | Empty state; populated row layout and action guards reviewed in source |
| Cache & Storage | Usage, budget, trim controls and native reset confirmation, then Cancel |

Related windows include both Assistant settings entry points, Calendar settings (Calendars, expanded Add a calendar, and Assistant & Scheduling), and Keyboard Shortcuts. All were inspected. The preceding profile/filter pass also checked schedule expansion, range editing, profile creation and invalid filter-size feedback. Native sign-out/delete confirmations keep their existing system presentation and behavior.

Light-mode inspection covered every category. Dark-mode checks covered populated Gmail forms, blocked senders and composing editors; the preceding pass covered profile/filter sheets and navigation in both appearances. Semantic colors and text styles remain in use throughout.

## Verification

- The production Debug build passed before concurrent Calendar changes began. The focused hosted run passed 45 tests across SettingsEditorTests, ComposeFeatureModelTests, CalendarModelTests and AssistantModelTests: `/tmp/tern-settings-all-pages-tests.log`.
- The final isolated preview build includes the last list and template styling corrections: `/tmp/tern-settings-all-pages-final-audit-build.log`. Independent source review found no remaining settings issues. Scoped parsing and whitespace checks passed.
- Preview apps are `/tmp/Tern Settings Complete Light.app` and `/tmp/Tern Settings Complete Dark.app`. Their disposable source snapshot is `/tmp/tern-settings-complete-source-55fax4zv`.
- Populated Gmail settings use a snapshot-only synthetic transport. Production settings models, preference keys, defaults, provider permissions and queued writes were not changed by this design pass. Live Gmail writes, real authorization, spoken VoiceOver, increased contrast and older macOS versions were not exercised.
- Later shared-checkout builds encountered concurrent work: first a missing CalendarPendingEvents type, then an initialization error at `App/Assistant/AssistantDiagramView.swift:128`. The final log is `/tmp/tern-settings-all-pages-final-build.log`. All 37 settings-owned source files match the successful isolated build; AssistantView's shared settings-sheet call also matches. Other AssistantView edits belong to the concurrent sidebar pass.
