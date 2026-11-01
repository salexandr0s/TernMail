# Settings design

Settings uses native macOS controls in a searchable sidebar window. Its default size is 800×620 points, with a 208-point sidebar and a 740×500 minimum. Grouped forms supply row spacing; switches and buttons keep their natural widths. Groups fit their controls, and longer pages scroll. Shared footers keep page actions visible while their forms scroll.

Editors use the shared `SettingsEditorSheet`: 480 points wide for profiles and 560 for filters and Assistant settings. Calendar settings became a Settings pane in the [macOS HIG alignment](plans/macos-hig-alignment.md), which also turned the sub-tabs into sidebar rows. Short forms fit their contents. Longer forms cap the scrolling area at 440 points, with validation and actions outside it. Profile schedules retain their existing modes and validation.

## Current pass — 2026-11-02

Calendar used an unpadded, non-scrolling stack instead of the grouped form used by the other settings panes. Both Calendar tabs now use the shared form, with inset section selectors, calendar identity and access details, named groups, and adaptive weekday controls. Long calendar and account names fit without pushing controls out of the window. Custom calendar colors remain visible alongside the standard palette.

Calendar name and color edits have Save and Revert actions and participate in the settings navigation discard guard. Switching calendars also asks before discarding edits. The draft retains the original calendar snapshot for conflict checks and uses the provider's canonical name. Changing the color of a calendar with a local display alias therefore no longer attempts a rename.

The design pass covered all 20 sidebar destinations: General, Mail Actions, Notifications, Connections, Account Settings, Profiles, Reading, Message List, Attachments, Writing, Templates, Signatures, Suggestions, Filters, Blocked Senders, Vacation Responder, Calendar, Assistant, Failed Changes, and Cache & Storage. Changes align controls and explanatory text, remove duplicate insets, bound account/address menus, improve empty states and accessible control names, and keep primary actions reachable. Message List uses four aligned swipe-action rows. Reading and the profile schedule editor retain their existing layouts.

Native inspection covered every destination in the light offline preview at the default size, Calendar in both appearances, and the New Profile sheet. Calendar color saving, Revert, and canceling both calendar-selection and settings-navigation discard prompts were exercised with synthetic data. A separate disposable preview at 740×500 checked dark Calendar with long identities, a custom ninth color, disabled management/sharing access, scrolling working hours and wrapping weekdays. It also covered populated Gmail signatures, filters, blocked senders, vacation settings, and the scrolling filter editor with a long forwarding address and fixed actions.

Verification:

- The Debug build and 68 app tests in eight suites passed: SettingsEditorTests, CalendarManagementTests, CalendarModelTests, AccountAppearanceTests, ComposeFeatureModelTests, AssistantWritingStyleTests, MailNotificationTests, and CacheBudgetTests. Log: `/tmp/tern-settings-design-tests-20261102.log`.
- The final Debug build passed after the shared accessibility labels and segmented-header alignment were applied: `/tmp/tern-settings-final-build-20261102.log`.
- Core passed 29 tests in CalendarPreferencesTests, SettingsQueueTests, GmailSettingsTests, and MailPreferencesStoreTests: `/tmp/tern-settings-core-tests-20261102.log`. SwiftPM resolution ran after the final Xcode build to normalize the package lockfile.
- Independent source review, scoped Swift parsing, and whitespace checks passed. The Calendar color regression now also covers a calendar with a local display alias.

The temporary populated preview source is `/tmp/tern-settings-fixture-source-20261102`, with its app under `/tmp/tern-settings-fixture-build-20261102/Build/Products/Debug/Tern.app`. Its synthetic model setup and smaller default size are confined to that snapshot. The main offline preview is `/tmp/Tern-Settings-Preview-20261102.app`. Both previews were closed after inspection.

No live provider writes or permission changes were made. Spoken VoiceOver, increased contrast, and older macOS versions were not exercised. The installed Release app was not replaced by this pass; follow the release/performance integration notes in `SESSION_HANDOFF.md` before installation.

## Earlier coverage — 2026-10-30

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
- The earlier light/dark preview apps were removed during consolidation. That pass was included in the installed app at the time; it does not include the newer source changes described above. Its disposable source snapshot is no longer present.
- Populated Gmail settings use a snapshot-only synthetic transport. Production settings models, preference keys, defaults, provider permissions and queued writes were not changed by this design pass. Live Gmail writes, real authorization, spoken VoiceOver, increased contrast and older macOS versions were not exercised.
- Consolidation on 2026-10-30 resolved the earlier integration uncertainty: the complete checkout passed 265 hosted tests in 46 suites and a universal Release build, with the settings, Calendar and Assistant work together. The earlier missing CalendarPendingEvents type and diagram initialization error are resolved. Logs: `/tmp/tern-consolidation-app-tests-20261030.log` and `/tmp/tern-consolidation-release-20261030.log`.
