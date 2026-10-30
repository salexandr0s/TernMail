# F15: Tern calendar integration

Updated: 2026-10-30. The approved scope is implemented on `codex/tern-unified`. Automated verification and synthetic native UI checks are recorded below. Google account round trips, system notification delivery and full Apple Calendar interaction parity still require live acceptance checks.

F15 follows the F00/F01 assistant foundation immediately in the [feature roadmap](ai-and-features-roadmap.md). Existing feature IDs keep their numbers. This design replaces the invitation-only Calendar API alternative in [milestone 4](milestone-4.md) and the EventKit agenda proposal in [milestone 5](milestone-5.md).

## Product scope

Build an Apple Calendar-style calendar inside Tern, using native SwiftUI and AppKit, backed directly by Google Calendar through Google accounts already connected to Tern. Apple Calendar's information hierarchy, familiar interactions and Day/Week/Month/Year views are the comparison target. Keep Tern's own implementation and assets.

| Area | Required behavior |
|---|---|
| Navigation | Mail and Calendar destinations retain their selection and scroll state. The same assistant stays available in both. |
| Views | Day, Week, Month and Year; Today, previous/next, jump to date, search, mini-calendar and calendar sidebar. |
| Sidebar | Calendars grouped by account, colors, visibility, shared calendars and visible access restrictions. |
| Interaction | Double-click create/edit, drag to move, resize, drag across days, keyboard navigation, copy/paste, duplicate, delete and undo. |
| Shared editor | Title, calendar, times, time zone, all-day, location, notes, URL, busy/free, privacy, recurrence, alerts and attendees. Manual creation, email suggestions and assistant proposals use this editor. |
| Meetings | Existing meeting links and linked attachments; Google Meet creation when the calendar supports it. Linked files do not trigger Drive uploads or permission changes. |
| Recurrence | Custom repeat rules, end conditions, single occurrence, whole series and this-and-following edits. Preview affected exceptions before a series split. |
| Calendar management | Secondary calendar creation and editing, calendar colors, sharing permissions, adding accessible Google calendars. Unsupported subscription setup opens Google Calendar settings. |
| Interchange | Review `.ics` imports before saving; export an event or calendar; print the selected date range. |
| Presentation | Dark mode, VoiceOver, keyboard operation, narrow windows, locale-aware dates and configurable week start. |

Apple Reminders, travel-time calculations and independent calendar-feed subscriptions are excluded. Existing subscriptions in the Google calendar list remain visible. Separate calendar-only accounts and hosted background synchronization follow later.

## Google authorization and setup

Reuse `AccountSession`, Keychain-backed authorization, the account's `GoogleSession`, and existing account identity checks. Calendar consent extends the Google connection. Cancelling consent, choosing another account or leaving required permissions unchecked must preserve the working Gmail session.

`AccountFeature` and `GoogleScopes` define these additions:

| Feature | Scopes requested |
|---|---|
| `calendar` | `https://www.googleapis.com/auth/calendar.events`, `https://www.googleapis.com/auth/calendar.calendarlist`, `https://www.googleapis.com/auth/calendar.events.freebusy` |
| `calendarManagement` | `https://www.googleapis.com/auth/calendar.calendars` |
| `calendarSharing` | `https://www.googleapis.com/auth/calendar.acls` |

Request management and sharing only when enabled. Calendar visibility, scheduling selection and assistant access are separate user choices. The existing base Gmail permissions remain part of authorization. These scope names and responsibilities are described in [Google's Calendar scope reference](https://developers.google.com/workspace/calendar/api/auth).

Before live verification, the project owner must enable **Google Calendar API** in the existing Google Cloud project that owns Tern's OAuth client. Add the requested scopes to the project's Google Auth Platform data-access configuration and retain the intended testers in the test audience. Reuse the existing desktop OAuth client, redirect handling and Keychain flow; no service account or server is required. API enablement and consent configuration are external setup and have not been performed by adding source files. [Google setup instructions](https://developers.google.com/workspace/calendar/api/quickstart/python#enable_the_api)

## Architecture and implementation contracts

| Layer | Implementation and responsibility |
|---|---|
| `GmailAPI` | `GoogleCalendarClient` implements `CalendarService` using the existing session transport. `GoogleCalendarModels` represents calendars, events, recurrence, attendees, free/busy and ACLs. Calendar network requests stay out of views. |
| `MailStore` | `CalendarStore` and `CalendarRecords` hold the Google mirror, occurrence windows, sync tokens, durable operations, email source links and suggestion corrections. The separate database is `calendar.sqlite`. |
| `SyncEngine` | `CalendarSyncEngine` synchronizes and reads calendars. `CalendarActionQueue` implements persistent operations; `CalendarRecurringOperations` checkpoints multi-step imports and splits. `CalendarAvailability` computes free intervals in ordinary Swift. |
| App coordinator | `CalendarModel` owns account engines, current view/date, display wrappers, freshness and proposals. Editing, proposals and calendar management live in separate extensions. |
| Native calendar UI | `CalendarView`, `CalendarGridViews`, `CalendarTimeGrid`, `CalendarEventEditor`, `CalendarRecurrenceControl`, `CalendarManagementView`, `CalendarActivityView` and `CalendarImportExport`. |
| Email integration | `CalendarDetection` and `CalendarInterchange` in `MessageContent`; `EmailCalendarModel`, `EmailCalendarSuggestionsView` and `EmailCalendarExtractionService` in the app. |
| Assistant | Typed `AssistantSource.Target`, `AssistantToolResult`, `AssistantCalendarScope`, injected `CalendarAssistantBindings`, `CalendarAssistantTools` and `AssistantCalendarActionsView`. |

Remote identity is the tuple `(accountID, calendarID, eventID)`. Preserve `iCalUID`, recurring master ID, original occurrence time, time zone and ETag. `CalendarDateTime` distinguishes an all-day date from an instant; exclusive all-day end dates remain dates. Event models retain unedited raw fields, and edits send the writable fields that changed rather than reconstructing and overwriting the entire event.

The disposable mirror is separate from local work: rebuilding Google data must retain `CalendarOperation`, `CalendarSuggestionRecord` and `CalendarSourceLink`. Removing an account removes that account's calendar data and cancels its work.

Calendar preferences belong to durable configuration, independent of disposable sync data. `AccountStore+CalendarPreferences` stores account/calendar visibility, assistant access, scheduling selection and alerts in `config.sqlite`, with account-removal cleanup. Global working hours/week start use `UserDefaults`. The app accesses preferences through its account-store adapter. The earlier `calendar.sqlite` preference accessors remain for compatibility and tests; a remote mirror reset must never remove the active configuration.

### Synchronization and freshness

1. Paginate calendar discovery and the complete event master/exception collection.
2. Apply a full or incremental event batch transactionally, persisting `nextSyncToken` only after every page succeeds.
3. On expired tokens, reset only the affected remote mirror and obtain a fresh full snapshot. Keep pending operations, proposals, suggestions and source links.
4. Ask Google for expanded occurrences in the displayed range; cache the range separately for offline views. Do not locally expand recurrence for the main display.
5. Use bounded free/busy requests for calendars whose access permits availability only.
6. Refresh at launch, app activation, reconnect and manual refresh. While Tern runs, poll every minute with Calendar visible and every five minutes otherwise. No hosted background sync is implied.
7. Revision/epoch checks invalidate older requests after mutations or permission changes. Views and assistant results distinguish loading, cached/stale and incomplete data.

This token handling follows [Google's incremental synchronization guidance](https://developers.google.com/workspace/calendar/api/guides/sync). A partial page sequence must not advance the saved sync cursor.

### Writes and recovery

`CalendarOperation` records stable operation identity, account/calendar, typed mutation, `sendUpdates`, timestamps, attempts, status, result event and multi-step checkpoints. States include `proposed`, `queued`, `running`, `completed`, `conflicted`, `failed` and `cancelled`.

Assistant tools can prepare durable proposals only. User Save in the shared event editor authorizes entering the queue; neither presenting a proposal nor choosing availability approves a write. The activity view exposes pending changes, conflicts and failures. Calendar invitations use Calendar API delivery; ordinary email replies use Tern's existing compose queue.

Creation uses a stable client-generated event ID and operation marker. After an uncertain response, reconcile the remote result before retrying. Updates/deletes use ETags and reject concurrent changes for review; permission and version checks run again before an offline operation is submitted. [Google conditional resource modification](https://developers.google.com/workspace/calendar/api/guides/version-resources)

This-and-following edits are resumable series splits: inspect the master and future exceptions, obtain explicit confirmation for exception resets, persist the planned replacement, trim the original series, remove affected exceptions and create the replacement using its stable ID. Persist completed steps so a restart cannot create another new series. A single daily, weekly, monthly or yearly rule can be partitioned with COUNT/UNTIL, weekday and ordinal filters, BYSETPOS, EXDATE and date/time RDATE. Counts follow nominal recurrence positions before exclusions. Multiple RRULEs, EXRULE, period-valued RDATE, advanced counted subdaily/BYWEEKNO/BYYEARDAY rules and off-rule RDATE split anchors return an explicit limitation. Moving an inherited schedule that contains future absolute EXDATE exclusions also requires review outside Tern. Whole-series deletion does not need to interpret those rules. These limitations prevent a split from silently changing the schedule.

Before Save, show the recipients of invitations, updates or cancellations. Preserve fields the editor did not change. Imports create personal copies and must not imply an organizer received an RSVP.

Calendar search reads visible calendars with event-detail permission within one year before and after the selected date. The UI displays the searched range and reports incomplete results. Google subscriptions already in the calendar list remain visible; subscription setup opens Google settings.

### Alerts

`CalendarNotifications` uses `UserNotifications` and popup reminders from the event or its calendar defaults. Reconcile the coming seven days after synchronization, edits and cancellations. Use account/calendar/event identity to remove obsolete requests and remove an account's requests on sign-out.

Already scheduled system alerts can fire while Tern is closed. Remote changes cannot revise those alerts until Tern runs again. Alert permission, scheduling and cancellation require a live macOS check; the app must not report notification delivery based only on a successful scheduling call. [Apple local notification delivery](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)

## Email event recognition

Use three layers without making AI a prerequisite for ordinary calendar use:

1. **Structured invitations:** extend the existing MIME/iCalendar parser to retain multiple VEVENTs, rules, exceptions and cancellation identity. Keep UID/RECURRENCE-ID, SEQUENCE and DTSTAMP ordering across cached messages. Continue excluding quoted attachments and irrelevant iTIP response methods from new invitations.
2. **Local dates:** `CalendarDetection` uses `NSDataDetector` over readable, unquoted text. Each Add event suggestion carries its literal supporting text. Relative phrases use the source message's date, not today's date; missing duration and time zone remain visible review items. [Apple data detection](https://developer.apple.com/documentation/foundation/nsdatadetector)
3. **Optional interpretation on read:** after mailbox AI opt-in, `EmailCalendarExtractionService` receives bounded messages through the existing provider. It returns schema-validated proposals, corrections and cancellations with source IDs and literal excerpts. `EmailCalendarModel` caches by thread revision, keeps dismissals and preserves user corrections. Access changes discard in-flight and retained AI-derived results.

Before creating an event, look for its Google invitation identity and occurrence. If it already exists, offer View event. A newer invitation offers a reviewed change; repeated delivery must not make another event. For a matching invitation with the user as attendee, use the Calendar API RSVP path.

For an unmatched invitation, expose separate **Add personal copy** and **Reply to invitation** actions. The personal copy uses import semantics; acceptance goes through the existing iTIP compose/Undo workflow. Choose exactly one delivery path for a response, including retries. [Google event import semantics](https://developers.google.com/workspace/calendar/api/v3/reference/events/import)

Store source-email links locally. Do not copy private email bodies into calendar notes automatically. Quoted or forwarded text, ambiguous dates and missing zones must not silently turn into confirmed commitments.

## Assistant permissions and scheduling

The assistant has separate per-calendar settings: **Off**, **Availability only**, **Event details**. Their persisted values are `off`, `availability` and `details`. Defaults are Off. Calendar display visibility grants no AI permission. A calendar-only question can run with no mailbox opted in; mail tools still require the current allowed mailbox/thread scope.

`AssistantCalendarScope` includes account/calendar keys, granted access and a revision. The assistant's full scope includes independent mail and calendar permissions. Changing either scope or the Google/ChatGPT connection invalidates the conversation epoch, active tools, retained context and proposals. Calendar citations are typed separately from mail citations; availability-only access cannot resolve a calendar event citation.

`CalendarAssistantBindings` exposes calendar descriptors, event reads, bounded occurrence queries, availability and proposal preparation. It deliberately exposes no queue approval, flush or remote write method. Registered tools are:

| Tool | Boundary |
|---|---|
| `list_calendars` | Lists only opted-in calendars, their access, writability and scheduling selection. |
| `read_calendar_events` | Reads/searches at most a 31-day range with event-details access; bounded results carry freshness/completeness. |
| `read_calendar_event` | Refreshes one identified event only with event-details access. |
| `check_availability` | Checks explicitly selected scheduling calendars and returns selectable intervals with checked calendars, zone, timestamp and failures. |
| `prepare_calendar_event` | Prepares an editable create/update proposal. Existing-event edits require details access. Save is a separate user action. |
| `prepare_calendar_deletion` | Fetches the current event and ETag with details access, then prepares a deletion proposal for a writable calendar. The editor reviews recurrence scope and recipients before Save; the tool sends no deletion or cancellation. |

Event titles, notes, locations, attendees and email bodies are untrusted source material. Their contents cannot grant access or authorize a calendar write. Tool validation runs before and after asynchronous reads, and the app verifies returned sources/proposals against the captured scope before retaining them.

The scheduling workflow is:

1. Read the allowed conversation and identify the date range, intended duration and time zone.
2. Query fresh availability across selected scheduling calendars. Across multiple Google accounts, combine their busy intervals before computing slots. A failed or inaccessible calendar is unknown, so return no confirmed slots for an incomplete calendar set.
3. Compute intervals with `CalendarAvailability.findSlots`, using the user's working hours. Defaults: Monday–Friday, 09:00–17:00 in the chosen zone; unspecified duration is visibly 30 minutes.
4. Present selectable options, for example: “Tomorrow you have 10:00–10:30 and 14:00–14:30 available. Which should I suggest?” Include the time zone and retrieval time; selection reserves nothing.
5. Recheck selected intervals against the same calendar set. If one is now busy or unknown, require new options.
6. Prepare an editable reply with the selected times through the existing composer. If its conversation is unclear, ask the user which conversation. Do not include private titles or reasons for other appointments. Sending remains a user action.

Other attendees' availability is usable only when Google grants access. Creating a meeting after choosing slots requires a separate reviewed event proposal. [Google free/busy API](https://developers.google.com/workspace/calendar/api/v3/reference/freebusy/query)

## Delivery sequence and gates

All five phases are F15 and follow the assistant foundation. Integrating code across phases does not waive their verification gates.

| Phase | Deliverable | Gate |
|---|---|---|
| 1. Connection and data | Incremental authorization, client/protocol, durable store, full/incremental sync, cached occurrence ranges and read-only views. | Consent failure preserves Gmail; pagination/token recovery/offline/account isolation tests; read live Google data. |
| 2. Calendar interaction | All views, shared editor, queue, recurrence, invitations, alerts and interaction controls. | Create/move/edit/delete round trips; ETag conflicts; interrupted writes/splits; alert rescheduling; UI interaction review. |
| 3. Email integration | Structured invitations, local date detection, reviewed imports, identity matching and source links. | AI-off dated mail; repeat/update/cancel deduplication; one RSVP delivery path; preserved corrections. |
| 4. Assistant scheduling | Typed sources, independent opt-ins, tools, slots, reply drafts and reviewed proposals. | Availability-only boundaries, revoked access, partial failures and multi-account busy union; end-to-end reply remains unsent. |
| 5. Completion | Calendar sharing/management, import/export, printing, accessibility and Apple Calendar comparison. | Round-trip interchange and invitation recipients; VoiceOver/dark/narrow/keyboard checks; remaining parity gaps resolved or explicitly recorded. |

## Verification record

Validation uses a frozen calendar-only source copy at `/tmp/tern-calendar-management-8jceolrq` because writing-style work is proceeding in the shared checkout. The snapshot includes the committed assistant and attachment library. No real emails, invitations or calendar events were sent during these checks.

| Check | Current status |
|---|---|
| Core suite | 369 tests in 57 suites passed; `/tmp/tern-calendar-verified-core.log`. |
| Calendar engine focus | 66 tests in 14 suites passed, including pagination, token expiry, uncertain writes, durable receipts, ETags, recurrence partitioning and account isolation. |
| Hosted app suite | 148 tests in 27 suites passed; `/tmp/tern-calendar-verified-app.log`. Includes calendar permissions, model lifecycle, management, email detection, assistant proposals, overlapping undo requests and keyboard callback routing. |
| Project generation and Debug compilation | Passed in the isolated snapshot. |
| Universal Release | Final arm64 and x86_64 Release build passed; `/tmp/tern-calendar-verified-release.log`. |
| Native presentation | Day, Week, Month and Year inspected with synthetic calendars; light/dark presentation, event editor and accessibility labels inspected. Create/edit/delete, menu undo, Mail sidebar recovery and Attachments/Calendar title transitions passed. Final interactive Command-Z verification is blocked by the locked Mac; a hosted routing regression covers the command boundary. |
| Google create/move/edit/delete and Google-to-Tern changes | Pending live account verification and Cloud API/consent setup. |
| Dated emails with AI disabled; repeated/updated/cancelled invitations | Automated detection, parser, source receipt, revision and reply-path tests pass; real inbox round trips remain pending. |
| Scheduling example | Automated scope, availability-only, partial-failure, multi-account and proposal tests pass. End-to-end model/provider selection and reply drafting remain a live acceptance check. Selecting slots does not enqueue an event or send mail. |
| Alerts while running/closed and rescheduling after edits | Implemented; actual macOS notification delivery remains pending. |
| Keyboard, VoiceOver, narrow windows and Apple Calendar comparison | Native accessibility tree inspected; spoken VoiceOver, narrow-window review and a complete parity checklist remain pending. The Mac locked during the final keyboard check. |

The preview uses `--ui-audit --ui-audit-calendar` and an in-memory `CalendarAuditService`. It is separate from the real Google session. Debug fixtures exercise the same editor and action queue, but cannot certify Google's invitations, ACLs, Meet behavior or eventual consistency.

Expected commands from the repository root:

```sh
swift test --package-path Packages/Core
xcodegen generate
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build build
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build test
```

Use the existing test scheme/host configuration when selecting focused app suites. Build-time model support does not replace live Google testing. The external Cloud configuration, provider-backed scheduling example and UI parity review remain explicit release gates.
