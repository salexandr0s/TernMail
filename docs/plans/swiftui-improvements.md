# SwiftUI improvement plan

## Scope

A review of the app target's SwiftUI code against the swiftui-pro references (API, views, data flow, navigation, design, accessibility, performance, Swift, hygiene). It covers `App/Views`, `App/Calendar`, `App/Assistant`, `App/Compose`, `App/Attachments`, `App/Settings`, `App/Accounts`, `App/Integration` and `App/Design`, 218 Swift files. `Packages/Core` is out of scope except where a value type should move there to become testable.

Line numbers refer to the working tree on 2026-10-31 at commit `0ea5511` plus the uncommitted list-density edits in `ThreadListView.swift` and `MessageListRow.swift`. The reviews were read-only; nothing in this document has been implemented.

The deployment target is macOS 14.0 (`project.yml`), which decides which fixes apply. Checked against the Xcode 26.3 SDK interface files:

- Usable now: `ContentUnavailableView`, `@Entry`, `contentMargins`, `onKeyPress`, `containerRelativeFrame`, `ViewThatFits`, `onGeometryChange` (macOS 13), `contentTransition` (macOS 13), `symbolEffect`, string inflection, `Date.IntervalFormatStyle`, `ByteCountFormatStyle`.
- Not usable: `searchFocused`, `onScrollGeometryChange` and the new `scrollPosition` (macOS 15); `Tab`, `@Animatable` and WebKit's SwiftUI `WebView` (macOS 26). The `NSSearchField` wrapper in `MailToolbar.swift` and the `WKWebView` wrapper in `MessageWebView.swift` stay.

The thirteen `NSViewRepresentable` wrappers, the `Task.detached` render path in `ThreadView.swift`, and the commented `nonisolated(unsafe)` and `@unchecked Sendable` sites were checked and are justified. They are not in this plan.

## Direction

- Derive in models, store the result, read it in body. A body should not parse, hash, format with a new formatter, rasterize, or filter a collection per cell.
- Bind to stored state. `Binding(get:set:)` lives only in a small set of shared helpers and in model-provided bindings.
- One shared component for each repeated pattern: contrast-aware outline, icon-only button, pasteboard copy, animation, swatch picker, error label.
- Standard controls over gestures. A `Button` with a title and `.labelStyle(.iconOnly)` gives VoiceOver, Voice Control and keyboard activation; an `Image` with an `accessibilityLabel` gives only the first.
- Child views over computed `some View` members, and one type per file for anything reused across files.
- Each phase ships as PRs of at most five files, built and tested before the next PR (workspace refactor rule).

## Findings

Severity is noted where it changes the order of work. Everything else is medium or low.

### Thread list

`App/Views/ThreadListView.swift`

- L330-442 `ThreadRow` and L483-517 `ThreadMenuItems` have no call sites in `App/` or `Tests/`. About 190 lines of dead code; the live row is `MessageListRow`. `ThreadDate` (L519) is used elsewhere and stays. Removed in `c1b7537`.
- L174-226 the `list` property decodes `storedColors` from `@AppStorage` and computes `compactAccountMarks` on every evaluation. Keep decoded colors on a stored property updated from `onChange(of: storedColors)`.
- L181 `List(selection:)` goes through `Binding(get:set:)` to reach `selectListRows`. Expose the validated binding from `MailboxModel` instead of building it in body.
- L197-205 pagination lives in `onAppear`. Move the "near the end" test into the model.
- L62-64 `isChoosingSnoozeDate` is a hand-written optional-to-Bool binding (shared helper, Phase 1).

`App/Views/MessageListRow.swift`

- L12 `@AppStorage("mailTextScale")` repeats the key that `ReadingPreferences.textScaleKey` already defines.
- L36, L63, L70 compute `NSFont.preferredFont(forTextStyle:).pointSize * scale` per row per evaluation. Compute the three scaled fonts once per scale change and pass them down through the environment.
- L29 `EmailAddress.parseList` runs per row. Store the parsed sender on `MessageListItem` when the projection is built.
- L96 `.accessibilityElement(children: .contain)` makes VoiceOver read avatar, sender, date, subject and snippet as separate elements. Compose one label (sender, subject, date, unread, attachment) as the dead `ThreadRow` did.
- `MessageListMenu` duplicates the NSPasteboard copy code and uses "Read / Unread" and "Star / Unstar" where the toolbar says "Mark as Read" and "Mark as Unread".

`App/Views/MessageListHeader.swift`

- L29-36 quick-filter toggles bind through `Binding(get: { filters.contains(filter) } ...)` (set-membership helper, Phase 1).
- L46 `"\(count) messages"` is a hand-pluralised string; use `"^[\(count) message](inflect: true)"`. The same pattern appears in seven Settings and Accounts files and in `AssistantMessageView.swift` L76 and L130.
- L94-150 an `extension MailboxModel` with `searchSuggestions` is model code in a view file. L127 `lowercased().contains` should be `localizedStandardContains`. The quote escaping here also exists in `MailboxModel+MessageList.swift` L117 and `RecipientField.swift` L114; one helper.

### Mail shell

`App/Views/MainView.swift`

- L35-74 a `GeometryReader` wraps the whole window to feed `AssistantSidebarLayout`, with three `onChange(initial: true)` relays. `onGeometryChange(for: CGSize.self)` on the content replaces it.
- L82-86 five `onChange` modifiers each call `app.assistant.refreshAccess()`. Replace with one `task(id:)` keyed on a `Hashable` snapshot, or let `AssistantModel` observe its inputs. `AssistantView.swift` L47-52 and `AssistantSettingsView.swift` L23-27 relay `connectionRevision` the same way.
- L116-232 `mailContent(topInset:)` is 116 lines. `.mailToolbarVisible(isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID)` appears at L182, L187, L191 and L193, with the inverse at L168 and L175. Extract `MailWorkspaceView` and compute `showsMailToolbar` once.
- L207-231 two near-identical `NoticeView` blocks.
- L275-330 single-key shortcut dispatch and the async reply flow are view code. Move `perform` and `canPerform` into a tested dispatcher on the model.
- L99 confirmation dialog over an optional through `Binding(get:set:)` (helper).

`App/TernApp.swift` L45 `.defaultSize(width: 720, height: 600)` is the one window size not taken from `Tokens.Layout`.

`App/Integration/MailWorkspaceColumns.swift` L23-25 stores `@ViewBuilder` closures and calls them in body. Build the three views in the initializer and store the views so SwiftUI can diff them.

### Thread reader

`App/Views/ThreadView.swift` (756 lines, five types, 26 `@State` properties)

- `ThreadView` holds 18 `@State` properties (L13-28) and a 223-line body with load, retry, calendar reply and cancellation flows inside closures (L80-96, L102-118, L131-139, L155-165, L265-296), plus `task(id:)` blocks with nested `Task` and `defer` (L198-264). Move the state and flows into a `@MainActor @Observable ThreadReaderModel` created per thread. The view keeps `expanded` and presentation state. The identity structs (`LoadIdentity`, `ReadIdentity`, `RenderIdentity`) are the right pattern and move with the model.
- L147-148 `.id(accountID + ":" + message.id).id(message.id)` chains two identities; the second wins. Keep one.
- L265 and L280 `confirmationDialog` and `alert` over optionals through `Binding(get:set:)` (helper).
- L339-346 a `Menu` with an `Image` label plus `accessibilityLabel`, and L386-391 the chip's `xmark` button. Use `Label` with `.labelStyle(.iconOnly)`.
- L358-366 `chips` reduces, filters and sorts in body.
- L401 `.overlay(Capsule().strokeBorder(...))` is the old overlay form (also `ContactAvatar.swift` L32).
- L407-451 `FlowLayout` belongs in `App/Design`.
- `MessageView` (L465-474, ten `@State` properties): L530 Combine `onReceive` for `imagePermissionChanged`; L585 `onTapGesture` on the snippet text with no button trait; L604 `ByteCountFormatter.string` per evaluation; L630-636 a static `DateFormatter` with hand-rolled relative output. Use `.formatted(.byteCount(style: .file))` and `Date.RelativeFormatStyle`.

### Sidebar

`App/Views/SidebarView.swift` (538 lines, ten types)

- L81-89 three sheets bind through `Binding(get:set:)` over `mailbox.navigation`. `MailNavigationModel` is `@Observable`, so `@Bindable var navigation = mailbox.navigation` and `$navigation.isCreatingSearch` work directly.
- L123-128 delete confirmation over an optional (helper).
- L147-151 `accountColors` decodes JSON from `@AppStorage` in body; L168-177 `expansion(of:)` splits a comma-joined string on every call; L180 `LabelNode.outline(...)` rebuilds the tree per evaluation with filters inside `ForEach` at L189-196. Keep decoded colors, the expanded-ID set and the per-account outline on the model, refreshed from `onChange`.
- L65-74 and L342-351 icon-only `plus` buttons.
- L244 the chevron animates with `.animation(reduceMotion ? nil : ..., value:)`; use `ternAnimation(value:)`.
- L253 and L399 `.font(.system(size:))`.
- L283-286 `onTapGesture(perform: selectAndToggle)` with `accessibilityAction(.default)`. A `Button` with `.buttonStyle(.plain)` gives the trait and keyboard activation.
- L428-459 `LabelNode` and L526-538 `Color(gmailHex:)` move to `App/Mailbox` and `App/Design`.

### Toolbar

`App/Views/MailToolbar.swift` L155-161 two optional-to-Bool bindings (helper). `SearchField` (L176) stays an `NSSearchField` wrapper until the target reaches macOS 15. The `#available(macOS 15, *)` branch in `mailToolbarVisible` is correct.

### Calendar (`App/Calendar`, 36 files)

Correctness, high

- `CalendarEventEditor.swift` L132-144 and L172-181: guest and alert rows use `id: \.offset` with index-based bindings. After `remove(at:)` rows re-key, a stale index can trap in the getter, and `.id("\(index)-\(reminder.method)")` rebuilds the row on every method change. Give rows stable identity (`ForEach($attendees, id: \.email)` and an `Identifiable` reminder row) and drop the `.id`.
- `CalendarView.swift` L21-31: a `GeometryReader` switches between `calendarPane(compact:)` and `HSplitView` at 760 pt, which destroys and recreates the grid subtree (drag state, frames, the 8 AM scroll). Keep one pane and toggle the sidebar, or use `ViewThatFits`.

Performance, high

- `CalendarPresentation.swift` L62-63: `start` and `end` are computed properties that build a `TimeZone` and parse the ISO date on every access (`GoogleCalendarModels.swift` L106). Every per-day filter reads both for every event. Resolve once when the display event is built and store `start`, `end` and a day key.
- `CalendarLayout.events(on:)` runs per cell: `CalendarTimeGrid.swift` L111-199 (about 21 filters per column per render, re-run on every drag move), `CalendarMonthGrid.swift` L70 (42 per render), `CalendarGridViews.swift` L190 (504 per year view), `CalendarScheduleView.swift` L13-17 (30 per month). One bucketing pass per render, or in the model, replaces all of them.
- `days` arrays are rebuilt in body and again in gesture helpers (`CalendarTimeGrid.swift` L22-25, `CalendarMonthGrid.swift` L30-65).
- Formatters are created in body: `DateIntervalFormatter` in `CalendarView.swift` L154-158, `CalendarSidebar.swift` L105-112 and `AssistantCalendarTypes.swift` L55. `EmailCalendarSuggestionsView.swift` L106 rebuilds `presentation` on each access and reads it ten times per row. Use `Date.IntervalFormatStyle` and compute once.
- `GeometryReader` plus `PreferenceKey` for frame tracking (`CalendarMonthGrid.swift` L182-186, `CalendarTimelineGesture.swift` L11-18) and for seven equal columns (`CalendarGridViews.swift` L116-124, L157-176). `onGeometryChange` and `.frame(maxWidth: .infinity)` remove the readers.

Structure

- `CalendarEventEditor.swift`: twelve `@State` fields mirror `CalendarEditorValues` and are copied back in `commit()` (L14-27, L258-263). Hold one `@State private var values` and bind `$values.title`. The 170-line body becomes one child view per section. `@State var draft` (L7) is not private.
- `CalendarRecurrenceControl.swift` L76-119 parses and serializes RRULE in the view while `SyncEngine/CalendarRecurrencePartition.swift` already has a parser. Extract a `RecurrenceRule` value type into Core and test it. L21-67 wrap every binding in `publishing(...)`; bind directly and `onChange` on one snapshot. L8-15 string-typed selections become enums.
- `CalendarTimelineGesture.swift` L117-126 drag math inline with a magic `15` instead of `snapMinutes`; move it beside the tested `CalendarInteraction` helpers.
- `CalendarManagementView.swift` L98-183 an 85-line builder spanning four sections; `Binding(get:set:)` at L137, L276, L282, L294; role strings repeated at L154, L196, L347-355.
- `CalendarGridViews.swift` holds four shared types; `CalendarView.swift` is 412 lines with four computed sections. Split by type.
- `WorkspaceView.swift` L52-54 Combine `onReceive` for app activation. A `.task` loop over `NotificationCenter.notifications(named:)`, or the model owning the refresh.

### Assistant (`App/Assistant`, 33 files)

Streaming hot path, high

- `AssistantMarkdownView.swift` L10 parses the markdown in body, so a growing reply is reparsed per token. Cache blocks with `.task(id: text)` and coalesce `textDelta` commits in `AssistantModel.run` to one mutation per frame.
- `AssistantConversationView.swift` L71-80 passes closures to each row and `AssistantMessage` is not `Equatable` (`AssistantConversation.swift` L18), so every visible row re-evaluates per token. Make `AssistantMessage: Equatable`, conform the row views and apply `.equatable()`. L59 and L120-128 build `Array(messages.enumerated())` and call `Calendar.current` per row; precompute `startsGroup` and `beginsDay` in the model.
- `AssistantMessageView.swift` L210-224: `emails` and `sources` are filtered and deduplicated up to five times per body. Dedup once in `AssistantModel.update`. L45-169 `bubble` is 125 lines; extract `RelatedMailSection`, `DraftButton` and `SourcesDisclosure`.
- `AssistantEmailCard.swift` L94 decodes `NSImage(data:)` in body.
- `AssistantDiagramView.swift` L11 measures text for every node per evaluation; cache per diagram. L35-42 `GeometryReader` only for the viewport width; `containerRelativeFrame`. L116 `Connection.route` is never read.
- `ThreadSummaryView.swift` L31 computes a SHA-256 over all messages on every evaluation and reads it at L39, L41 and L66. Compute once per `ThreadDetail`. L66-77 load orchestration belongs in `ThreadSummaryModel.reload`.
- `AssistantView.swift` L140 reads `model.messages.isEmpty`, so the header, scope picker and composer re-run per token and rebuild `AssistantContext` through `availableAccounts` (L52) and `canSubmit` (L227-229). Expose a stored `hasMessages`.

Layout and structure

- `AssistantConversationView.swift` L12 and L44-53 nest a `GeometryReader`, a `PreferenceKey` and a named coordinate space to read the viewport and content frames. Two `onGeometryChange` calls replace all of it.
- `AssistantSidebarLayout.swift` L35-159 `AssistantMailPaneSizing` walks the NSView hierarchy from `updateNSView` and every `layout()` pass to call `NSSplitView.setPosition`, duplicating what `navigationSplitViewColumnWidth` already requests in `MainView.swift` L127-131 and L150-154, and `requestApply()` re-arms on every width change. Test whether the column-width constraints alone hold when min, ideal and max are equal on macOS 14 and 15. If the probe stays, make it a plain representable-owned controller with a regression test. L39 `private struct Divider` shadows `SwiftUI.Divider`.
- The contrast-aware stroke `RoundedRectangle().strokeBorder(contrast == .increased ? .primary : border)` is copied 17 times across eight files while `TernSurface` already implements it for one radius. One `ternOutline(radius:)` modifier.
- `AssistantSettingsView.swift` L283-286 and `AssistantWritingStyleSettingsSection.swift` L69-72 set-membership bindings; L48-120 duplicates `accountRow`. `AssistantCalendarActionsView.swift` L25-27 the same binding.
- `AssistantView.swift` L85-88, L116-120, L165-168, L172-175, L244-249 icon-only images with separate accessibility labels. `openWindow(id: "main")` at L241 and in `AssistantCalendarActionsView.swift` L14 is a magic string.
- `.caption2` on interactive rows: `AssistantMessageView.swift` L200 (Copy, Try again), `AssistantEmailCard.swift` L26, L30, L69, `AssistantView.swift` L161 (a hint containing a button).
- `AssistantMarkdownView.swift` L135-267 and `AssistantDiagramView.swift` L109-219 hold the parser and the layout type; own files.

### Compose (`App/Compose`, 23 files)

Per-keystroke fan-out, high

- `SenderAccountLabel.swift` L28-33 rasterizes the avatar with `ImageRenderer` inside body. The From row re-renders on every Subject keystroke and once per menu item. Render once in the avatar model when the image, `showsLogos` or color scheme change, and store the `NSImage`. L31 `NSScreen.main?.backingScaleFactor` should be `@Environment(\.displayScale)`.
- `RichTextEditor.swift` L328-333 `publish()` rebuilds the whole `ComposeDocument` on every `textDidChange`, then compares it twice (O(n) each), and `updateNSView` L102-103 byte-compares every inline image `Data`. Coalesce publishes (50 to 100 ms, flush on focus-out and before send) and compare images by key.
- `RecipientField.swift` L84 `configureAvatars()` runs on every `updateNSView`, which marks all three token fields dirty on every ComposeView render. Cache the configuration key in the coordinator and skip when unchanged. L411-424 `publish()` writes partially typed text into `model.content.to` per keystroke, which cancels and recreates the autosave task and runs `chooseRecipientAccountIfNeeded()`. Publish tokens immediately and typed text on tokenize or end-editing. `RecipientTokenField.swift` L42-48 builds a fresh text storage per `draw`.
- `ComposeSignatureView.swift` L15 runs `MessageDocument.render(html:)` (SwiftSoup parse plus sanitize) inside body on every content change. Cache with `.task(id: html)` or expose the rendered signature from `ComposeModel`.

Structure and data flow

- `ComposeView.swift` (610 lines, four types): L358-361 a `Binding(get:set:)` per recipient row per render; L515-517 `isShowingAlert`; L103-104 `onAppear` plus `onChange` where L182-184 sorts and joins IDs into a string per render; L150-151 and L250 filters in body; L163-168 drop logic and L477, L486, L499 `Task` blocks inline. Split into `ComposeHeader`, `ComposeFromMenu`, `QuotedTextDisclosure`, `ComposeToolbar` and `LinkEditor` files.
- `RecipientField.swift` L249-311 the suggestion state machine (generation, 300 ms debounce, dedupe) sits inside a delegate callback. Extract `RecipientSuggestionLoader` into Core so it is testable.
- `ComposeTextView.swift` L46-85 markdown auto-format scanning is pure logic inside an `NSTextView` override. Move it into `MessageContent` as `MarkdownAutoFormat.replacement(in:caret:)` with tests.
- `LocalSignaturesPane.swift` L104-106 three `task` modifiers chain into up to three loads per appearance, two discarded by a generation counter (L129-136). One `.task(id: AssignmentKey)` and delete the counter. L121-164 persistence and eleven `@State` fields in the view. `SuggestionBlocklistPane.swift` L85-86 has the same double reload, and `ComposeTemplatesPane.swift` L92-109 the same persistence shape. One shared `@Observable` model for the three panes.
- `AttachmentStrip.swift` L105, L118, L128-131 `UTType(filenameExtension:)`, `ByteCountFormatter` and `NSWorkspace.shared.icon` in body. `FormatBar.swift` L41 a write-only binding that needs a comment or a `Button` with `.isSelected`.

### Attachments (`App/Attachments`, 8 files, plus `ReceivedAttachmentsView.swift`)

- `AttachmentLibraryCollection.swift` L139 `select(_:)` reads `NSApp.currentEvent?.modifierFlags`, but the same method is reached from `.accessibilityAction` (L181) and arrow-key `moveSelection` (L160), where the current event is a key event or stale. Shift and command range selection can misfire for keyboard and VoiceOver users. Pass modifiers explicitly; the tap path forwards the flags, other paths pass `[]`. Correctness, medium.
- `AttachmentLibraryView.swift` L17-18 `filterCount` and `hasFilters` build every filter chip (date and byte formatting) per body, and the same builder runs again in `AttachmentLibraryFilters.swift` L66 and L165: four builds per render. Expose cheap booleans from the model. L26-32 `GeometryReader` only to read width; `onGeometryChange`. L12 `@AppStorage("attachments.viewMode")` is a raw string; an enum.
- `AttachmentLibraryRows.swift` L179 and L211 resolve `UTType` and `NSWorkspace.shared.icon` per row per render, and every card reads `model.selection` so all cards re-render on each selection change. A `@MainActor` icon cache keyed by type identifier, or a presentation struct built once per page. L59 and L67 fixed column widths are duplicated in `AttachmentLibraryCollection.swift` L62-63.
- `AttachmentLibraryFilters.swift` L78-103 three `Binding(get:set:)` in body, one allocating a `NumberFormatter` per set for MB-to-bytes conversion. Model-side `hasStartDate`, `startDay` and `minimumMB` with `TextField(value:format:)`.
- `AttachmentLibraryView.swift` L95, L179, L208, L211, L258 icon-only buttons.
- `ReceivedAttachmentsView.swift` L88-91 Save All stops silently when one chip is already loading. Skip and continue, then report how many were saved.

### Settings and accounts (`App/Settings`, `App/Accounts`, `App/Integration`)

Data flow, medium

- `SignaturesPane.swift` L33 seeds `signatureOnReplies` from the store in `.task`; when the stored value is `true` the assignment fires the `onChange` at L13, which writes the same value back through `updateAccount` on every open. Guard on change or let the model own the value.
- `MaintenanceSettingsView.swift` L65 `onChange(of: budget)` runs `enforceBudget()` at once, which trims cached mail with no confirmation or debounce. Needs a product decision: confirm, debounce, or apply on leaving the pane.
- `ConnectionsView.swift` L26-29, `AccountPreferencesView.swift` L93-100 and L125, `NotificationSettingsView.swift` L41-44, `SidebarSettingsView.swift` L13-16 and L35-38 bind toggles through `Binding(get:set:)` with a `Task` in the setter, so the switch does not move until the async refresh lands. Local `@State` plus `onChange`, or an `onToggle` variant of `SettingsToggleRow`.
- `FilterEditorSheet.swift` L56, L163, L176 `Binding(get:set:)` chains over optional draft fields; L62 a byte size bound as text. Make `FilterEditorDraft` fields non-optional and use `TextField(value:format:)`. `VacationPane.swift` L26, L76, L80 and `ProfileScheduleView.swift` L13-22, L140-156 the same shape, the latter doing calendar maths per `DatePicker` per render.
- Confirmation dialogs over optionals attached to the container rather than the triggering button: `FiltersPane.swift` L69, `AccountsSettings.swift` L48, `ProfilesView.swift` L49, `TriageControls.swift` L41.

Work in body

- `AccountPreferencesView.swift` L119 JSON-decodes the `@AppStorage` blob and is read for each of eight swatches: sixteen decodes per render. `FavoritesView.swift` L86-90 decodes the same blob per row. Decode once per body, or keep it on a model.
- `SettingsMessageEditor.swift` L34-36 `changed` and `savedHTML` serialize HTML on every access; `VacationPane.swift` L46-66 and `SignaturesPane.swift` L70-74 read them two or three times per render. Memoize by a document revision.
- `MailboxSwitcher.swift` L18-20 and L52-78 rebuild the full accounts-by-labels option list and filter it on every access, read five times per body. Build once in `.task`, filter once with `let`.
- `MessageActions.swift` L70-76 `primaryReply` parses sender, recipients and cc, and is read three times at L27-29.
- `OriginalMessageView.swift` L30 decodes up to 2 MB into `Text` on every render.
- `SettingsView.swift` L47 and L72 run `matches(search)` over every destination twice per body. `FilterEditorSheet.swift` L158 `validation`, `LabelEditorSheet.swift` L49 `problem`, `BlockedSendersPane.swift` L49-51 `blocked` and `FiltersPane.swift` L37-41 label lookups repeat the same pattern.
- `SettingsComponents.swift` L25-32 `GeometryReader` plus `onAppear` plus `onChange` to measure content height; `onGeometryChange`. L75 `SettingsGroup.init` discards its `systemImage` parameter while all 34 call sites pass one: render it or remove it.
- `AddressAvatar.swift` L62-64 `onAppear` plus `onChange(of: identity)` plus a stored `configuredIdentity` hand-roll `.task(id:)`, which `DomainLogoAvatar.swift` L38 already does correctly. L4-13 a manual `EnvironmentKey` while `@Entry` is used six times elsewhere.

Accessibility

- `FavoritesView.swift` L41-48 `onTapGesture` handles selection and expansion with no button trait or accessibility action; L20-27 an icon-only `Menu` with only `.help`. `MailboxSwitcher.swift` L34 `onTapGesture(count: 2)` on list rows has no keyboard or VoiceOver equivalent; `OutboxView.swift` L30-41 shows the `contextMenu(forSelectionType:primaryAction:)` form to copy.
- `MaintenanceSettingsView.swift` L90 shows the over-budget state by color only.

Design system

- `Tokens.swift` has no font-weight or tint tokens; `.weight(.medium)` and `.weight(.semibold)` are hand-applied at about 130 sites across the app, and opacities such as `0.10` and `0.16` (`ProfilesView.swift` L123, L203) are literals. Either add `Tokens.Font` and `Tokens.Tint`, or standardize on `.bold()` and the semantic text styles. `Layout.settingsWidth` duplicates `Settings.width` (L104-129 against L79-94).
- `Components.swift` L108-121 `TernSurface` has a fixed radius, so `SettingsComponents.swift` L206-224 and `SettingsMessageEditor.swift` L70-76 re-implement it. Add a `radius:` parameter. L62-73 and `ContactAvatar.swift` L36-42 are two different initials algorithms. L76-106 `TernEmptyState` duplicates `ContentUnavailableView`, which six other files also hand-roll.
- `ProfilesView.swift` L149, L186-238 and `AccountPreferencesView.swift` L48, L66-87 duplicate the color-name array and the swatch picker. `IntegrationSettingsView.swift` L129-135 and `MaintenanceSettingsView.swift` L103-109 duplicate `errorMessage`. `LabelAppearancePicker.swift` L139-161 and L246-269 duplicate arrow-key grid navigation.
- `PopupComponents.swift` L22-23 the generic header hard-codes "Choose label icon".
- `MessageWebView.swift` holds seven types in 314 lines; `RemoteContentBlocker`, `RuleListBox` and `MessageWebViewWarmup` are not part of the representable.
- `SettingsPanes.swift` L5, L22, L42 `Int` tab selection with magic tags; `SavedSearchEditor.swift` L20-46 a `"__subset"` sentinel string as a Picker tag; `ReadingSettingsView.swift` and `AttachmentLibraryView.swift` store raw strings in `@AppStorage` where `RawRepresentable` enums bind directly.
- `KeyboardShortcutsView.swift` L8-27 maintains shortcut strings by hand, apart from the `Commands` definitions.

### Counts across the app target

| Pattern | Sites | Replacement |
| --- | --- | --- |
| `Binding(get:set:)` in body | 45 | three helpers plus model-provided bindings |
| `.weight(.medium)`, `.weight(.semibold)` or `fontWeight` | about 130 | `.bold()` or weight tokens |
| `.caption2` | 35 | `.caption` on anything read or tapped |
| icon-only `Button` or `Menu` labels | 20 | `Button(title, systemImage:)` and `.labelStyle(.iconOnly)` |
| `onTapGesture` | 15 | `Button`, or `.accessibilityAddTraits(.isButton)` where the gesture must stay |
| `GeometryReader` | 13 | `onGeometryChange`, `containerRelativeFrame`, `frame(maxWidth:)` |
| `.font(.system(size:))` | 12 | text styles, or scaled fonts computed once |
| hand-pluralised count strings | about 10 | `^[...](inflect: true)` |
| custom empty states | 7 | `ContentUnavailableView` |
| `@State var` not private | 6 | `private` |
| `ForEach(... id: \.offset)` | 9 | stable identity where rows are edited or removed |
| old `overlay(Shape)` form | 3 | `.overlay { }` |
| manual `EnvironmentKey` | 1 | `@Entry` |
| `#Preview` | 0 | add for the reused components |

No `foregroundColor`, `cornerRadius`, `NavigationView`, `ObservableObject`, `AnyView`, `try!` or single-parameter `onChange` remain anywhere. All 33 `@Observable` classes are main-actor isolated.

## Work phases

Order matters. Phases 0 and 1 unblock everything after them. Phase 2 fixes behavior. Phase 3 is the largest user-visible gain. Phases 4 to 6 pay down structure. Each PR touches at most five files and ends with the checks in Verification.

### Phase 0: cleanup, no behavior change

- Delete `ThreadRow` and `ThreadMenuItems` from `ThreadListView.swift`. Done in `c1b7537`.
- `MessageListRow.swift` reads `ReadingPreferences.textScaleKey` (done with the list refinement). `TernApp.swift` L45 takes its size from `Tokens.Layout`.
- Remove `Connection.route`; rename the private `Divider` in `AssistantSidebarLayout.swift`; drop or render the `systemImage` parameter on `SettingsGroup`.
- Make the six non-private `@State` properties private. Convert the three old-form overlays. Replace the manual `EnvironmentKey` in `AddressAvatar.swift` with `@Entry`.
- Move `LabelNode`, `Color(gmailHex:)`, `FlowLayout`, `searchSuggestions`, `AssistantMarkdown`, `AssistantDiagramLayout`, the three non-web types in `MessageWebView.swift`, `AttachmentChip`, `ProfilePicker` and the shared calendar grid types into their own files. One PR per area.

### Phase 1: shared helpers

- `App/Design/Binding+Tern.swift`: `isPresent()` on `Binding<T?>`, `contains(_:)` on `Binding<Set<T>>`, and `or(_:)` for optional-with-default. Then replace the 45 sites in PRs of five files, favoring `@Bindable` on nested observables and model-provided bindings over the helpers wherever the state is already stored.
- `ternOutline(radius:)` modifier and a `radius:` parameter on `TernSurface`; a `copyToPasteboard(_:)` helper; `SettingsErrorLabel`; `SwatchPicker` with `AccountAppearance.names`; one initials function; a `SettingsToggleRow` variant that takes an async `onToggle`.
- A `GmailQuery.quoted(_:)` helper for the three quote-escaping copies.
- Decide on weight tokens versus `.bold()`, and on `Tokens.Tint`, before Phase 5 applies either.

### Phase 2: correctness

- Stable row identity in the event editor's guest and alert lists.
- `CalendarView` stops recreating the grid across the 760 pt threshold.
- `AttachmentLibraryCollection.select` takes modifiers explicitly.
- `SignaturesPane` no longer writes on load. `MaintenanceSettingsView` budget change gets a confirmation or a debounce after a product decision.
- `ThreadView` keeps one `.id`. `ReceivedAttachmentsView` Save All reports partial results.
- `AssistantMailPaneSizing`: measure whether `navigationSplitViewColumnWidth` alone holds on macOS 14 and 15. Remove the probe if it does; otherwise isolate it behind a representable with a regression test.

### Phase 3: performance

Profile first with the Instruments SwiftUI template and record body counts for the three scenarios in Acceptance, so each PR can show the before and after.

- Calendar: stored `start`, `end` and day key on `CalendarDisplayEvent`; one per-day bucketing pass replacing `events(on:)`; `days` computed once per body; `Date.IntervalFormatStyle`; `presentation` computed once per row.
- Assistant: `AssistantMessage: Equatable` and `.equatable()` rows; cached markdown blocks, diagram layout and decoded avatars; coalesced `textDelta` commits; stored `hasMessages`; thread summary revision computed once; email and source dedup in the model.
- Compose: avatar rasterized once in the model; coalesced `RichTextEditor.publish`; image comparison by key; gated `configureAvatars`; recipient text published on tokenize; cached signature render.
- Mail: scaled fonts and parsed sender precomputed for `MessageListRow`; decoded account colors and compact marks stored for the thread list and sidebar; sidebar outline and expansion set on the model; `MailWorkspaceColumns` stores views; the five `refreshAccess` relays become one.
- Attachments and settings: filter chips built once; UTType and icon cache per row; `AccountAppearance` decoded once; `savedHTML` memoized; `MailboxSwitcher` options built once; `primaryReply`, `validation`, `problem`, `blocked` and `matches(search)` hoisted to `let`; `OriginalMessageView` decoded once.

### Phase 4: view structure

- `ThreadView` moves its flows into `ThreadReaderModel` and splits into `ThreadHeader`, `ThreadMessageList` and `MessageView` files.
- `MainView` extracts `MailWorkspaceView`, a tested shortcut dispatcher and one `NoticeView` placement. The window `GeometryReader` becomes `onGeometryChange`.
- `CalendarEventEditor` holds one `values` struct and one child view per section. `CalendarView`, `CalendarManagementView`, `ComposeView`, `AssistantMessageView`, `AssistantView` and `AssistantSettingsView` extract their computed sections into child views.
- `RecurrenceRule` moves to Core with tests; the drag math joins `CalendarInteraction`; `RecipientSuggestionLoader` and `MarkdownAutoFormat` move to Core; the three compose settings panes share one model.
- Remaining `GeometryReader` uses drop to three or fewer, each with a comment saying why.
- Enum-typed selections replace the `Int` tabs in `SettingsPanes.swift`, the `"__subset"` sentinel and the raw-string `@AppStorage` values.

### Phase 5: accessibility and design

- Icon-only controls become `Button(title, systemImage:)` or `Menu(title, systemImage:)` with `.labelStyle(.iconOnly)` (20 sites).
- `onTapGesture` selection in `FavoritesView`, `SidebarView` and `MailboxSwitcher` becomes a `Button` or a list primary action; the snippet toggle in `ThreadView` gets a button trait.
- `MessageListRow` exposes one composed accessibility label per row.
- `.caption2` audit: `.caption` for any text that is read or contains a control (35 sites, most in Assistant and Calendar).
- Hand-pluralised strings use inflection. Menu titles match the toolbar ("Mark as Read", "Mark as Unread").
- `ternAnimation(value:)` replaces the ad hoc reduce-motion check in `SidebarView`. Over-budget and unread states gain a non-color cue under `accessibilityDifferentiateWithoutColor`.
- The weight and tint decision from Phase 1 is applied app-wide; `.font(.system(size:))` sites use text styles or the scaled fonts.
- `ContentUnavailableView` replaces the seven custom empty states, including `TernEmptyState`.

### Phase 6: previews and tests

- `#Preview` for `MessageListRow`, `ThreadHeading`, `LabelChip`, `CalendarEventChip`, `AssistantMessageView`, `AttachmentChip` and the Settings components, fed by the Debug fixtures in `App/Debug/AvatarAuditFixtures.swift` and small inline records.
- Tests in `TernTests` for the binding helpers, the shortcut dispatcher, calendar bucketing, the editor row identity regression and the pane-sizing probe. Core tests for `RecurrenceRule`, `RecipientSuggestionLoader` and `MarkdownAutoFormat`.

## Acceptance

- No body in `App/` parses, hashes, rasterizes, creates a formatter, or filters a collection per cell. The counts table reads zero for the first eight rows, or the remaining sites carry a comment.
- `Binding(get:set:)` appears only in `Binding+Tern.swift` and in model methods that return bindings.
- `GeometryReader` appears at most three times, each commented.
- Every control has a text title. VoiceOver reads a thread row as one element with sender, subject, date and state. Keyboard and VoiceOver selection in the attachment library never applies a shift or command range by accident.
- Streaming a long assistant reply re-evaluates only the streaming row (Instruments body count stays flat for the other rows).
- Dragging an event in the week and month views runs one bucketing pass per frame, not one filter per cell.
- Typing in the compose subject does not re-render the From avatar or redraw the recipient token fields.
- Removing a middle guest or alert in the event editor keeps the remaining rows' state.
- Opening the Signatures pane performs no account write.
- `xcodebuild`, `swift test --package-path Packages/Core` and the `TernTests` target pass after every PR.

## Verification

```bash
xcodegen generate
swift test --package-path Packages/Core
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build build
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build test -only-testing:TernTests
```

For Phase 3, profile with the Instruments SwiftUI template before and after each PR, recording body evaluation counts for: streaming a 2,000-word assistant reply; dragging an event across a week; typing 50 characters into a compose subject with three recipients. Attach the counts to the PR.

For Phases 2 and 5, run the Accessibility Inspector audit on the main window, the compose window and Settings, then check VoiceOver on the thread list, the sidebar and the attachment library, and check the app with Reduce Motion and Increase Contrast on.
