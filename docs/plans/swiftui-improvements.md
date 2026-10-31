# SwiftUI improvement plan

## Scope

A review of the app target's SwiftUI code against the swiftui-pro references (API, views, data flow, navigation, design, accessibility, performance, Swift, hygiene). It covers `App/`, 229 Swift files. `Packages/Core` is out of scope except where a value type should move there to become testable.

The review was written at `75374d4` for a macOS 14.0 target. This revision re-checks every finding at `58101df`, after twenty feature commits and the move to macOS 26.0 in `d615e5c`. Line numbers refer to `58101df`.

The deployment target is macOS 26.0 (`project.yml`), so every SwiftUI API in the installed SDK is usable. Checked against the MacOSX 26.2 SDK interface files in Xcode 26.3, and for WebKit with a type-check at both targets:

- Newly usable APIs this plan adopts: `onScrollGeometryChange`, `onScrollPhaseChange`, `scrollPosition(_:)` with a `ScrollPosition`, `presentationSizing` and `onModifierKeysChanged` (macOS 15).
- Assessed and not adopted yet: `searchFocused` and `searchToolbarBehavior` for the toolbar search field, WebKit's SwiftUI `WebView` and `WebPage` for the message view, and `TextEditor` over `AttributedString` for compose (macOS 15 and 26). The sections concerned say why.
- The `@Animatable` macro compiles at any target in this SDK.
- `Text + Text` is deprecated at macOS 26. No site remains in `App/`.
- A Debug build of `58101df` reports no deprecation warnings. It reports one Swift 6 warning in the app target, at `MessageListRow.swift` L54 (Phase 2).

The fourteen `NSViewRepresentable` wrappers, the `Task.detached` render path in `ThreadView.swift`, and the three commented `nonisolated(unsafe)` and `@unchecked Sendable` sites were checked. All are justified except where a finding below says otherwise.

## Status at `58101df`

Phase 0 (`035b43c` to `a7801f2`), Phase 1 (`2b6fbab` to `88def6b`) and Phase 2 (`23bd6f3` to `16d0572`) finished after this review; their entries under Work phases list the commits. The findings below still cite line numbers at `58101df`. At that revision no phase had started as planned work. Feature commits since `75374d4` finished these items along the way, and the sections below no longer list them:

- `ThreadRow` and `ThreadMenuItems` were deleted (`c1b7537`).
- `MessageListRow` reads `ReadingPreferences.textScaleKey` (`2012eb2`) and exposes one accessibility element with a composed summary (`b71eb0e`).
- The list menu says "Mark as Read", "Mark as Unread" and "Remove Star", matching the toolbar (`2012eb2`, `b71eb0e`).
- The snippet tap in `ThreadView` moved to the message header, which the avatar and chevron buttons make reachable by keyboard and VoiceOver (`1bee764`).
- Opening the Signatures pane no longer writes the reply setting back (`c5ebd40`).
- Lowering the cache budget asks before trimming, and only when the cache is over the new budget (`c5ebd40`). This settles the product decision the first edition left open.
- Settings panes select through the `SettingsDestination` enum instead of `Int` tags (`c5ebd40`).
- `MessageActions` computes `primaryReply` once (`1bee764`).
- The popup header takes its title as a parameter, and the shortcuts window reads `ShortcutCatalog` instead of hand-kept strings (`15d5cb8`).
- The macOS 14 availability branches are gone (`d615e5c`).

Three items are partly done. `OriginalMessageView` moved its decode into a child view but still decodes in body (`1bee764`). Five calendar strings gained inflection (`d8f74a1`, `10fafa3`). `Tokens.Opacity` exists (`15d5cb8`), but opacity literals remain.

The same commits added new instances of the patterns this plan removes, and `Binding(get:set:)` sites rose from 60 to 64. The new findings are folded into the sections below: the time zone picker, calendar sheet sizing, the received-attachment preview flow, the duplicated attachment search state, `WorkspaceSection` in the launcher file, and the Swift 6 warning in `MessageListRow`.

## Direction

- Derive in models, store the result, read it in body. A body should not parse, hash, format with a new formatter, rasterize, or filter a collection per cell.
- Bind to stored state. `Binding(get:set:)` lives only in a small set of shared helpers and in model-provided bindings.
- One shared component for each repeated pattern: contrast-aware outline, icon-only button, pasteboard copy, animation, swatch picker, error label, empty state.
- Standard controls over gestures. A `Button` with a title and `.labelStyle(.iconOnly)` gives VoiceOver, Voice Control and keyboard activation; an `Image` with an `accessibilityLabel` gives only the first.
- System APIs over measurement, now that the target allows them: scroll geometry and `ScrollPosition` over readers and sentinels, `presentationSizing` over reading the key window, `onModifierKeysChanged` over `NSApp.currentEvent`.
- Child views over computed `some View` members, and one type per file for anything reused across files.
- Each phase ships as commits of at most five files, built and tested before the next commit (workspace refactor rule).

## Findings

Severity is noted where it changes the order of work. Everything else is medium or low.

### Thread list

`App/Views/ThreadListView.swift`

- L203-210 the `list` property decodes `storedColors` and calls `compactAccountMarks` (L292-304) on every evaluation. Keep the decoded colors and marks on stored state, updated from `onChange(of: storedColors)`.
- L211 `List(selection:)` goes through `Binding(get:set:)` to reach `selectListRows`. Expose the validated binding from `MailboxModel` (`MailboxModel+MessageList.swift` L31-38).
- L229-237 pagination lives in a per-row `onAppear`. Move the "near the end" test into the model, driven by `onScrollGeometryChange` with a distance-to-bottom threshold so the next page loads before the last row appears.
- L221-222 every row builds a `Binding(get:set:)` for the snooze date popover (shared helper, Phase 1).

`App/Views/MessageListRow.swift`

- L54 reads the main-actor property `textLeading` inside the `alignmentGuide` closure, which the Swift 6 build reports as a warning. Capture the value in a local before the modifier. Correctness, medium.
- L33-35 `scaledFont` calls `NSFont.preferredFont(forTextStyle:).pointSize * scale` at twelve sites per row (L72-136). Compute the scaled fonts once per scale change and pass them through the environment.
- L62 `EmailAddress.parseList` runs per row. Store the parsed sender on `MessageListItem` when the projection is built.
- L19-22 `displayedLabels` filters the account's labels and is read three times per evaluation (L47, L127, L157). L128-130 look up the icon and parse `Color(gmailHex:)` per label per row. Store both on `MessageListItem`.
- L81-90 the star button has an `Image` label plus `accessibilityLabel`. Use `Label` with `.labelStyle(.iconOnly)`.
- L169 and L172 pluralise counts by hand in `accessibilitySummary`. Use inflection.
- L205 and L215 in `MessageListMenu` repeat the NSPasteboard copy code (shared helper).

`App/Views/MessageListHeader.swift`

- L29-35 quick-filter toggles bind through `Binding(get: { filters.contains(filter) } ...)` (set-membership helper, Phase 1).
- L46 `"\(count) messages"` is hand-pluralised and reads "1 messages"; use `"^[\(count) message](inflect: true)"`. `ThreadView.swift` L838 does the same with "tracking image(s)".
- L94-150 an `extension MailboxModel` holding `currentMailboxMessageCount`, `performSwipe` and `searchSuggestions` is model code in a view file. L127 `lowercased().contains` should be `localizedStandardContains`. The quote escaping at L128 and L143 also exists in `MailboxModel+MessageList.swift` L129 and `RecipientField.swift` L114; one helper.

### Mail shell

`App/Views/MainView.swift`

- L69-108 a `GeometryReader` wraps the whole window to feed `AssistantSidebarLayout`, with three `onChange(initial: true)` relays (L98-107). `onGeometryChange(for: CGSize.self)` on the content replaces it.
- L377-390 the `AssistantAccessRefresh` modifier has five `onChange` modifiers that each call `app.assistant.refreshAccess()`. Replace them with one `task(id:)` keyed on a `Hashable` snapshot, or let `AssistantModel` observe its inputs.
- L137-252 `mailContent(topInset:)` is 116 lines. `mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID` repeats at L110, L204, L208, L217 and L225 although `showsLibrary` (L33) already computes it. Extract `MailWorkspaceView` and use the one flag.
- L229-246 two near-identical `NoticeView` blocks.
- L295-350 single-key shortcut dispatch and the async reply flow are view code. Move `perform` and `canPerform` into a tested dispatcher on the model.
- L406-409 the sign-out dialog binds an optional through `Binding(get:set:)` (helper).

`App/TernApp.swift` L52 `.defaultSize(width: 720, height: 600)` on the New Message scene is the one window size not taken from `Tokens.Layout`.

`App/Integration/MailWorkspaceColumns.swift` L50-52 stores `@ViewBuilder` closures and calls them in body (L57, L59). Build the views in the initializer and store them so SwiftUI can diff them.

### Thread reader

`App/Views/ThreadView.swift` (935 lines, seven types, 30 `@State` properties)

- `ThreadView` holds 21 `@State` properties (L15-35) and a 266-line body (L104-369). Its closures run the load, retry, calendar reply and selection flows (L112-150, L164-189, L219-229), and its `task(id:)` blocks nest `Task` and `defer` (L267-336). Move the state and flows into a `@MainActor @Observable ThreadReaderModel` created per thread. The view keeps `expanded` and presentation state. The identity structs and `ReaderPaging` move with the model.
- L190-191 `.id(accountID + ":" + message.id).id(message.id)` chains two identities; the second wins. Keep one.
- L337-338 and L352-353 `confirmationDialog` and `alert` bind optionals through `Binding(get:set:)` (helper).
- L487-494 a `Menu` with an `Image` label, and L543-551 the chip's `xmark` button. Use `Label` with `.labelStyle(.iconOnly)`.
- L511-519 `chips` reduces, filters and sorts in body.
- L423 and L558 use the old `.overlay(Shape().strokeBorder(...))` form, as does `App/Design/ContactAvatar.swift` L32.
- L568-612 `FlowLayout` is also used by `ReceivedAttachmentsView.swift` L32 and `AssistantEmailCard.swift` L48. Move it to `App/Design`.
- `MessageView` (nine `@State` properties, L631-639): L704-710 a Combine `onReceive` for `imagePermissionChanged`; L784 `ByteCountFormatter.string` per evaluation, where `.formatted(.byteCount(style: .file))` fits.
- L877-886 `senderName` and `senderAddress` parse the sender on every access (L698, L706, L740, L747, L895), and L800 runs `parseList` per render under `id: \.offset`. Parse once on `MessageDetail`.

### Sidebar

`App/Views/SidebarView.swift` (543 lines, seven types, three extensions)

- L82 the switcher sheet binds `mailbox.navigation` through `Binding(get:set:)`, as does `SavedSearchEditor.swift` L99-100. `MailNavigationModel` is `@Observable`, so `@Bindable var navigation = mailbox.navigation` and `$navigation.isCreatingSearch` work directly.
- L118-123 delete confirmation over an optional (helper).
- L142-146 `accountColors` decodes JSON per body and L198-204 `sidebarNames` is rebuilt per body. L163-172 `expansion(of:)` splits a comma-joined string on every call, and L175 rebuilds the `LabelNode` outline with filters inside `ForEach` at L184-191. Keep these on the model, refreshed from the `onChange` at L92-96.
- L66-75, L346-355 and `SavedSearchEditor.swift` L97 are icon-only `plus` buttons.
- L239 the chevron animates with `.animation(reduceMotion ? nil : ..., value:)`; use `ternAnimation(value:)`.
- L248 and L403 use `.font(.system(size:))`.
- L279-282 `onTapGesture(perform: selectAndToggle)` with `accessibilityAction(.default)`. A `Button` with `.buttonStyle(.plain)` gives the trait and keyboard activation.
- L524-529 `sidebarCount` only forwards to `sidebarBadgeCount`. Remove it.
- L433-464 `LabelNode` and L531-543 `Color(gmailHex:)` move to `App/Mailbox` and `App/Design`.

### Toolbar

`App/Views/MailToolbar.swift` L157-163 two optional-to-Bool bindings (helper). The search field is now `WorkspaceSearchField` in `WorkspaceSearch.swift` (L82). It stays an `NSSearchField` wrapper for a new reason: the comment at L7-9 says the system search item inside a customizable toolbar rebuilds the toolbar on every layout pass on macOS 26, so the window never finishes opening. `searchFocused` and `searchToolbarBehavior` only apply to `.searchable`, so retest that bug on each new SDK before replacing the wrapper. No `#available` branch remains in `App/`.

### Calendar (`App/Calendar`, 38 files)

Correctness, high

- `CalendarEventEditor.swift` L131-145 and L171-181: guest and alert rows use `id: \.offset` with index-based bindings (L142, L173, L176). After `remove(at:)` (L143, L178) the rows re-key, a stale index can trap in the getter, and `.id("\(index)-\(reminder.method)")` (L180) rebuilds the row on every method change. Give rows stable identity (`ForEach($attendees, id: \.email)` and an `Identifiable` reminder row) and drop the `.id`.
- `CalendarView.swift` L24-37: a `GeometryReader` switches between `calendarPane(compact:)` and `HSplitView` at `Tokens.Calendar.compactWidth`, which destroys and recreates the grid subtree with its drag state, frames and the 8 AM scroll (`CalendarTimeGrid.swift` L81-100, `ScrollViewReader` plus `onAppear`). Keep one pane and toggle the sidebar. Move the initial scroll to `scrollPosition(_:)` with a `ScrollPosition` held on the model, so it survives a rebuild.

Performance, high

- `CalendarPresentation.swift` L80-81: `start` and `end` are computed properties that build a `TimeZone` and resolve the date on every access (`GoogleCalendarModels.swift` L106, which creates a `DateFormatter` for local date-times at L112). Every per-day filter reads both for every event. `color` (L83, and `CalendarDisplayCalendar` L62) parses hex and allocates a dynamic `NSColor` on every access. Resolve `start`, `end`, a day key and the color once when the display event is built, and store them.
- `CalendarLayout.events(on:)` runs per cell: `CalendarTimeGrid.swift` L129, L145 and L199 (21 filters per week render, re-run on every drag move, plus L149 and L225 for the preview), `CalendarMonthGrid.swift` L77 (42 per render), `CalendarGridViews.swift` L199 (504 per year view), `CalendarScheduleView.swift` L16 and L36. One bucketing pass per render, or in the model, replaces all of them.
- `days` is computed and read many times per body and in gesture helpers: `CalendarTimeGrid.swift` L24-27 (read at L31, L33, L93, L110, L129, L137 and `CalendarTimelineGesture.swift` L155-158) and `CalendarMonthGrid.swift` L32 (L43, L72, L224).
- Formatters are created during evaluation: `DateIntervalFormatter` in `CalendarView.swift` L167-171, `CalendarSidebar.swift` L146-153 (per agenda row) and `AssistantCalendarTypes.swift` L55-58, and a `DateFormatter` in `CalendarManagementView.swift` L321-328 that runs twice per body (L289-290). `EmailCalendarSuggestionsView.swift` L106 rebuilds `presentation` on each access, and the row reads it about twenty times. Use `Date.IntervalFormatStyle` and `Date.FormatStyle`, and compute once.
- `CalendarTimeZonePicker.swift` L62-66: `filtered` runs twice per evaluation (L37, L49) over every known zone, building a `TimeZone` and its localized name per candidate (L73-76), and L41 formats an offset per row. Precompute one static table of identifier, localized name and offset, and match with `localizedStandardContains`.
- `GeometryReader` plus `PreferenceKey` tracks frames (`CalendarMonthGrid.swift` L199-203, `CalendarTimelineGesture.swift` L11-18) and lays out seven equal columns (`CalendarGridViews.swift` L121-129, L166-184). `CalendarTimeGrid.swift` L30-39 and `CalendarMonthGrid.swift` L35-37 read only the size. `onGeometryChange` and `.frame(maxWidth: .infinity)` remove the readers.

Structure

- `CalendarEventEditor.swift`: twelve `@State` fields (L14-26) mirror `CalendarEditorValues` and are copied back in `commit()` (L258-264). Hold one `@State private var values` and bind `$values.title`, which also removes the `Binding(get:set:)` pickers at L186 and L189. The 172-line body (L61-232) becomes one child view per section. `@State var draft` (L7) is not private.
- `CalendarEventEditor.swift` L317-322: `CalendarSheetLayout.height` reads `NSApp.keyWindow` during body for the editor (L227-228), `CalendarActivityView.swift` L31 and `CalendarImportExport.swift` L232. `presentationSizing(.form.fitted(horizontal: false, vertical: true))` lets the system size and clamp these sheets.
- `CalendarRecurrenceControl.swift` L77-120 parses and serializes RRULE in the view, while `SyncEngine/CalendarRecurrencePartition.swift` L140 already has a private parser. Extract a `RecurrenceRule` value type into Core and test it. L22-58 wrap every binding in `publishing(...)` (L66-68), and L41-47 add another; bind directly and `onChange` on one snapshot. The string-typed selections at L8 and L11 become enums. L69-76 pluralise by hand; use inflection.
- `CalendarTimelineGesture.swift` L115-127 drag math inline, with a magic `15` (L123) instead of `CalendarInteraction.snapMinutes` (`CalendarInteraction.swift` L35). Move it beside the tested helpers.
- `CalendarManagementView.swift` L96-181 an 86-line builder spanning four sections; `Binding(get:set:)` at L135, L276, L282 and L294; role strings repeated at L152, L194 and L362-370.
- `CalendarView.swift` L72-75, L86-89 and L308-310 present dialogs through `Binding(get:set:)` over optionals (helper). `CalendarSidebar.swift` L80 builds a per-row visibility binding; expose it from the model.
- `CalendarSidebar.swift` L14 and L68-74 mirror `model.selectedEventID` into a local `selection` with two `onChange` relays. Keep one source of truth on the model.
- Icon-only `Image` labels with a separate `accessibilityLabel`: `CalendarView.swift` L138-141, `CalendarGridViews.swift` L152-157, `CalendarEventEditor.swift` L143 and L178, `CalendarManagementView.swift` L201. Use `Label` with `.labelStyle(.iconOnly)`.
- `CalendarGridViews.swift` holds four shared types (L67, L118, L133, L213), and `CalendarView.swift` is 396 lines with four computed sections (L135, L185, L229, L256). Split by type.
- `WorkspaceView.swift` L65-67 Combine `onReceive` for app activation. A `.task` loop over `NotificationCenter.notifications(named:)`, or the model owning the refresh.

### Assistant (`App/Assistant`, 33 files)

Streaming hot path, high

- `AssistantMarkdownView.swift` L10 parses the markdown in body, so a growing reply is reparsed per token. Cache blocks with `.task(id: text)` and coalesce the `textDelta` commits in `AssistantModel.swift` L603-606 to one mutation per frame.
- `AssistantConversationView.swift` L71-80 passes closures and `model.statusText` to each row, and `AssistantMessage` is not `Equatable` (`AssistantConversation.swift` L18), so every visible row re-evaluates per token. Make `AssistantMessage: Equatable`, conform the row views and apply `.equatable()`. L59 and L120-128 build `Array(messages.enumerated())` and call `Calendar.current` per row; precompute `startsGroup` and `beginsDay` in the model.
- `AssistantMessageView.swift` L210-224: `emails` and `sources` are filtered and deduplicated on every read, nine reads per body (L64-76, L114-130). Dedup once in the tool-result merge at `AssistantModel.swift` L675-686. L45-169 `bubble` is 125 lines; extract `RelatedMailSection`, `DraftButton` and `SourcesDisclosure`.
- `AssistantEmailCard.swift` L94 decodes `NSImage(data:)` in body.
- `AssistantDiagramView.swift` L11 builds `AssistantDiagramLayout` per evaluation, and L130-138 measure every label with `boundingRect`; cache the layout per diagram. L35-42 `GeometryReader` only for the viewport width; `containerRelativeFrame`. L116 `Connection.route` is read only by `AssistantMarkdownTests`, which checks that arrows clear other nodes.
- `ThreadSummaryView.swift` L30-33 computes a SHA-256 over all messages on every `identity` read, and it is read five times (L39, L41, L66, L67, L75). Compute once per `ThreadDetail`. The L66-77 load orchestration belongs in `ThreadSummaryModel.load` (`ThreadSummaryModel.swift` L65).
- `AssistantView.swift` L140 reads `model.messages.isEmpty`, so the header, scope picker and composer re-run per token and rebuild `AssistantContext` through `availableAccounts` (L52), `setupPrompt` and `canSubmit` (L214-229, read at L30, L178, L201). Expose a stored `hasMessages`.

Layout and structure

- `AssistantConversationView.swift` L12-17 and L43-53 nest a `GeometryReader`, a `PreferenceKey` and a named coordinate space to read the viewport and content frames for `AssistantScrollTracking` (L139-173). One `onScrollGeometryChange` replaces all of it. `scrollPosition(_:)` with a `ScrollPosition` and `scrollTo(edge: .bottom)` replaces `ScrollViewReader`, the `assistant-bottom` sentinel and the `Task.yield` at L106-118, and `onScrollPhaseChange` can mark user scrolls without inferring them from frame deltas. Keep `AssistantScrollTrackingTests` passing.
- `AssistantSidebarLayout.swift` L33-192 `AssistantMailPaneSizing` does two jobs. For column widths, probes in `MainView.swift` L145 and L165 walk up to the `NSSplitView` on every `updateNSView` and `layout()` pass (L168-190); `beginPresentation` records the user's widths on open (L53-63), `apply` pushes both panes to their minimums with `setPosition` and restores the recorded widths on close (L129-158), and `requestApply()` resets a three-try budget on every `mailWidth` change (L112-116, `MainView.swift` L103 and L273). It also measures a missing toolbar inset and publishes `contentTopInset` (L95-108), which `MainView.swift` applies to all three columns (L144, L164, L181). `MainView.swift` L151-155 and L174-178 already set min, ideal and max equal while the assistant shows. Test on macOS 26 with `setPosition` disabled, at 960 and 1280 points wide, after dragging both columns away from their defaults: both columns should reach the minimum from the constraints alone, the 960 case should collapse navigation without resizing the window, and closing should restore the dragged widths rather than the `ideal` defaults. If only restore fails, keep a small width-restore helper. Split the safe-area inset into its own type and check whether macOS 26 still needs it. `Tests/AppTests/AssistantSidebarLayoutTests.swift` already covers `apply()` and stays as the regression test. L39-43 `private struct Divider` shadows `SwiftUI.Divider`.
- The contrast-aware outline, `strokeBorder(contrast == .increased ? .primary : border)`, is copied 13 times across eight files at radii other than `TernSurface`'s (`Components.swift` L116): `AssistantDiagramView.swift` L53, L101; `AssistantMarkdownView.swift` L76, L109; `AssistantView.swift` L130; `AssistantWelcomeView.swift` L81; `AssistantMessageView.swift` L96-100, L136-140, L151-155, L163-167; `ComposeTemplatesPane.swift` L56; `SettingsMessageEditor.swift` L73; `SettingsComponents.swift` L197-201. Nine more sites combine it with focus, hover, a header border or a non-rectangular shape. One `ternOutline(radius:)` modifier with an optional focus color.
- `AssistantSettingsView.swift` L283-286 and `AssistantWritingStyleSettingsSection.swift` L69-72 set-membership bindings, and `AssistantCalendarActionsView.swift` L25-27 the same binding. The writing-style `accountRow` (L48-120) repeats the identity block of the settings `accountRow` (L263-296).
- `AssistantView.swift` L85-88, L116-120, L165-168, L172-175, L244-249 icon-only images with separate accessibility labels. `openWindow(id: "main")` at L241 is a magic string that also appears in `AssistantCalendarActionsView.swift` L14, `MailViewCommands.swift` L42, `MailURLRouter.swift` L124 and `TernApp.swift` L218. Give the main window a `sceneID` like `AssistantWindow.swift` L6.
- `.caption2` on interactive rows: `AssistantMessageView.swift` L200 (Copy, Try again), `AssistantEmailCard.swift` L26, L30, L69, `AssistantView.swift` L161 (a hint containing a button).
- `AssistantLauncher.swift` L3-15 declares `WorkspaceSection`, which `MainView.swift` and `WorkspaceSearch.swift` use. Move it and the two workspace toolbar types into their own files. L41 adds a `Binding(get:set:)` for the section picker.
- `AssistantMarkdownView.swift` L133-267 and `AssistantDiagramView.swift` L107-219 hold the parser and the layout type; own files.

### Compose (`App/Compose`, 23 files)

Per-keystroke fan-out, high

- `SenderAccountLabel.swift` L28-33 rasterizes the avatar with `ImageRenderer` inside body. The From row re-renders on every Subject keystroke and once per menu item (`ComposeView.swift` L256, L268). Render once in the avatar model when the image, `showsLogos` or color scheme change, and store the `NSImage`. L31 `NSScreen.main?.backingScaleFactor` should be `@Environment(\.displayScale)`.
- `RichTextEditor.swift` L328-333 `publish()` rebuilds the whole `ComposeDocument` on every `textDidChange` and compares it at L332, then `ComposeModel.swift` L78 compares the whole `DraftContent` again, O(n) each. Coalesce publishes (50 to 100 ms, flush on focus-out and before send).
- `RecipientField.swift` L84 `configureAvatars()` runs on every `updateNSView` and, through `RecipientAvatarController.swift` L122, marks the field dirty, so every ComposeView render redraws all three token fields. Cache the configuration key in the coordinator and skip when unchanged. L411-424 `publish()` writes partially typed text into `model.content.to` per keystroke, which restarts the autosave task and runs `chooseRecipientAccountIfNeeded()` (`ComposeModel.swift` L617-618). Publish tokens immediately and typed text on tokenize or end-editing. `RecipientTokenField.swift` L42-48 builds a fresh text storage and layout manager per `draw`.
- `ComposeSignatureView.swift` L15 runs `MessageDocument.render(html:)` (SwiftSoup parse plus sanitize) inside body on every content change. Cache with `.task(id: html)` or expose the rendered signature from `ComposeModel`.

Structure and data flow

- `ComposeView.swift` (610 lines, four types): L358-361 a `Binding(get:set:)` per recipient row per render; L515-517 `isShowingAlert`; L103-104 `onAppear` plus `onChange`, where L182-184 sorts and joins IDs into a string per render (use `onChange(of:initial: true)` on a model-side key); L150-151 and L250 filters in body; L163-168 drop logic and L477, L486, L499 `Task` blocks inline. Split into `ComposeHeader`, `ComposeFromMenu`, `QuotedTextDisclosure`, `ComposeToolbar` and `LinkEditor` files.
- `RecipientField.swift` L249-311 the suggestion state machine (generation, 300 ms debounce, dedupe) sits inside a delegate callback. Extract `RecipientSuggestionLoader` into Core so it is testable.
- `ComposeTextView.swift` L46-85 markdown auto-format scanning is pure logic inside an `NSTextView` override. Move it into `MessageContent` as `MarkdownAutoFormat.replacement(in:caret:)` with tests. L91-93 `draggingUpdated` calls `attachables(on:)` on every mouse move, which re-encodes a dragged TIFF to PNG each time (L113-115). Resolve it once in `draggingEntered` and reuse it for the drag.
- `RichTextEditor.swift` L35-37 the doc comment says the editor is an `NSTextView` because SwiftUI's rich text editing needs macOS 26. The target is now macOS 26, and the wrapper stays for other reasons (see below), so the comment should name them: TextKit 1 lists, image attachments, and the paste and typing hooks.
- `LocalSignaturesPane.swift` L97-99 three `task` modifiers chain into up to three loads per appearance, two discarded by a generation counter (L122-123, L129). One `.task(id: AssignmentKey)` and delete the counter. L114-157 persistence and eleven `@State` fields (L8-18) in the view. `SuggestionBlocklistPane.swift` L83-84 has the same double reload, and `ComposeTemplatesPane.swift` L91-108 the same persistence shape. One shared `@Observable` model for the three panes.
- `AttachmentStrip.swift` L105, L118, L128-131 `UTType(filenameExtension:)`, `ByteCountFormatter` and `NSWorkspace.shared.icon` in body. `FormatBar.swift` L41 a write-only binding that needs a comment or a `Button` with `.isSelected`.

SwiftUI's rich `TextEditor(text:selection:)` over `AttributedString` exists at macOS 26 but does not replace `RichTextEditor` or `ComposeTextView`. Its text attributes cover font, colors, underline, strikethrough, kern, tracking, baseline offset, alignment, line height and Genmoji glyphs. The compose editor also needs:

- Lists: `RichTextEditor.swift` L56-58 chooses TextKit 1 so Return continues or ends a list, and `AttributedDocument.swift` L31-39 and L189-191 build `NSTextList` paragraph styles. The SDK has no list attribute for the SwiftUI editor.
- Inline images: `ComposeImageAttachment` is an `NSTextAttachment` subclass that keeps each image's content ID through editing and Undo. The SwiftUI editor has no general attachment attribute.
- Typing and paste hooks: markdown auto-format, paste routing and drag handling override `insertText`, `paste` and the drag methods (`ComposeTextView.swift` L36-101). The SwiftUI editor exposes none of these.

The HTML round-trip lives in `ComposeDocument` in Core and would survive a new `AttributedString` mapping, so it is not the blocker. Revisit when the SDK adds list and attachment attributes.

### Attachments (`App/Attachments`, 8 files, plus `ReceivedAttachmentsView.swift`)

- `AttachmentLibraryCollection.swift` L139 `select(_:)` reads `NSApp.currentEvent?.modifierFlags`, but the same method is reached from the accessibility default action (L181) and arrow-key `moveSelection` (L160), where the current event is a key event or stale. Shift and command range selection can misfire for keyboard and VoiceOver users. Pass modifiers explicitly: the arrow handler at L101 already has `press.modifiers`, the accessibility path passes `[]`, and the tap at L178 reads flags kept current by `onModifierKeysChanged(mask: [.shift, .command])`. Correctness, medium.
- `ReceivedAttachmentsView.swift` L79-91 `preview` downloads every attachment in order before Quick Look opens, so clicking a small file waits for the largest. `download` (L120-124) returns nil for a file that is already downloading, so a preview that overlaps Save All, or a second click, silently drops files or opens nothing. Save All (L108-118) stops at L112 on the same nil and never says so. Show the clicked file first and add the others as they arrive; share in-flight downloads through a `[String: Task<URL?, Never>]` instead of returning nil; Save All skips failures and reports how many files it saved. Correctness, medium.
- `AttachmentLibraryView.swift` L17-18 `filterCount` and `hasFilters` build every filter chip (date and byte formatting) per body, and the same builder runs again in `AttachmentLibraryFilters.swift` L66 and L165: up to four builds per render. Expose cheap booleans from the model. L26-32 `GeometryReader` only to read width; `onGeometryChange`. L12 `@AppStorage("attachments.viewMode")` is a raw string compared as a string in `AttachmentLibraryCollection.swift` L24 and L55; an enum.
- `AttachmentLibraryRows.swift` L179 and L211 resolve `UTType` and `NSWorkspace.shared.icon` per row per render, `tint` (L215) resolves the type again, and `EmailAddress.parseList` runs up to three times per row (L197, L204, L226). Every card reads `model.selection` (`AttachmentLibraryCollection.swift` L176), so all cards re-render on each selection change. A `@MainActor` icon cache keyed by type identifier, or a presentation struct built once per page. The fixed column widths at L59 and L67 are duplicated in `AttachmentLibraryCollection.swift` L62-63.
- `AttachmentLibraryFilters.swift` L78-103 three `Binding(get:set:)` in body, one allocating a `NumberFormatter` per set (L95) for MB-to-bytes conversion. Model-side `hasStartDate`, `startDay` and `minimumMB` with `TextField(value:format:)`.
- `AttachmentLibraryDestination.swift` L22-23 keeps `toolbar.searchText` and `model.search` in step with two `onChange` handlers, two sources of truth for one value. One owner, and bind the other field to it.
- `AttachmentLibraryView.swift` L95, L179, L208, L211, L258 icon-only buttons.

### Settings and accounts (`App/Settings`, `App/Accounts`, `App/Integration`)

Data flow, medium

- `ConnectionsView.swift` L24-33, `AccountPreferencesView.swift` L121-123 and L125-127, `NotificationSettingsView.swift` L36-39 and `SidebarSettingsView.swift` L13-16 bind controls through `Binding(get:set:)` with a `Task` in the setter. `AccountPreferencesModel.update` (L101-104) refreshes only after the store write lands, so the control lags until then. Follow `SignaturesPane.swift` L15-20, which sets local state first, or add an `onToggle` variant of `SettingsToggleRow`.
- `FilterEditorSheet.swift` L53 and L110-116 chain `Binding(get:set:)` over optional criteria fields; L59 binds a byte size as text. Make the `FilterEditorDraft` fields non-optional and use `TextField(value:format:)`. `VacationPane.swift` L27, L84, L87 and `ProfileScheduleView.swift` L13-22, L140-156 have the same shape, the latter doing calendar maths per `DatePicker` per render.
- `ProfilesView.swift` L53-58 builds an optional confirmation by hand with `Binding(get:set:)`, and `TriageControls.swift` L41 does the same for its error alert. Use `ternConfirm(item:)` (`Components.swift` L179-194), as `FiltersPane.swift` L39 does.

Work in body

- `AccountPreferencesView.swift` L137 `colorIndex` JSON-decodes the `@AppStorage` blob on every access and is read at L105 and L114 for each of eight swatches: sixteen decodes per render. `FavoritesView.swift` L97-100 decodes the same blob per account row, and L94 rebuilds `shortNames` for every account per row. Decode once per body, or keep it on a model.
- `SettingsMessageEditor.swift` L34-36 `changed`, `savedHTML` and `savedPlainText` serialize on every access; `VacationPane.swift` L91-105 reads them through `hasChanges` (L48, L61, L75) and `validationMessage` (L56, L75). Memoize by a document revision.
- `MailboxSwitcher.swift` L18-20 and L53-77 rebuild and filter the full accounts-by-labels option list on every access; body reads it at L27 and L39, and L44, L45 and L48 read it again. Build once, filter once with `let`.
- `OriginalMessageView.swift` L94 decodes up to 2 MB into `Text` whenever `OriginalMessageText` renders. Decode once in `load()` (L48-60) into state.
- `SettingsView.swift` L89 and L114 run `matches(search)` over every destination twice per body. `FilterEditorSheet.swift` L108 `validation` (read at L21, L39), `LabelEditorSheet.swift` L49 `problem` (five reads, L91-135), `BlockedSendersPane.swift` L43-45 `blocked` (L14, L19, L32) and the per-row label lookups in `FiltersPane.swift` L86-95 repeat the pattern.
- `SettingsComponents.swift` L37-45 `GeometryReader` plus `onAppear` plus `onChange` to measure content height; `onGeometryChange`. L104-118 `SettingsGroup` is now a bare `Section(title)` that discards its `systemImage` (L108) at 22 call sites: replace it with `Section` and delete the type. `TriageControls.swift` L64-65 and `SidebarSettingsView.swift` L20-21, L46-47 keep card padding left over inside grouped forms.
- `AddressAvatar.swift` L62-63 `onAppear` plus `onChange(of: identity)` plus a stored `configuredIdentity` (L39) hand-roll `.task(id:)`, which `DomainLogoAvatar.swift` L38 already uses. L4-13 a manual `EnvironmentKey` while `@Entry` is used 13 times elsewhere.

Accessibility

- `FavoritesView.swift` L45-52 `onTapGesture` handles selection and expansion with no button trait or accessibility action; L23-30 an icon-only `Menu` with only `.help`. `MailboxSwitcher.swift` L34 `onTapGesture(count: 2)` has no keyboard or VoiceOver equivalent; `OutboxView.swift` L30-41 shows the `contextMenu(forSelectionType:primaryAction:)` form to copy.
- `MaintenanceSettingsView.swift` L94 shows the over-budget state by tint only. L89 and L96 give the numbers but never say the cache is over budget.

Design system

- `Tokens.swift` has no font-weight tokens, and about 110 sites apply `.weight(.medium)` or `.weight(.semibold)` by hand. `Tokens.Opacity` (L51-56) exists, but `ProfilesView.swift` L123 (`0.10`) and L203 (`0.16`) still use literals. `Layout.settingsWidth` (L167) is unused, and `Layout.settingsHeight` (L168) only seeds `SettingsEditorSheet` (`SettingsComponents.swift` L14).
- `Components.swift` L108-121 `TernSurface` has a fixed radius, so `SettingsComponents.swift` L186-204 `SettingsSurface` (used only by `AssistantSettingsView.swift` L149 and `AssistantWritingStyleSettingsSection.swift` L44) and `SettingsMessageEditor.swift` L70-76 re-implement it. Add a `radius:` parameter. `Components.swift` L62-73 and `ContactAvatar.swift` L36-42 are two different initials algorithms.
- `TernEmptyState` (`Components.swift` L76-106, 24 call sites) and `ContentUnavailableView` (seven sites, six in Settings plus `ConversationWindow.swift` L47) give empty states two looks. Pick one, or make `TernEmptyState` wrap the system view. `SettingsView.swift` L114-121 could become `ContentUnavailableView.search(text:)`.
- `ProfilesView.swift` L149 and L215-236 duplicate the color names and swatch picker from `AccountPreferencesView.swift` L73 and L94-117. Error labels are duplicated with different icons: `IntegrationSettingsView.swift` L146-152 (triangle), `MaintenanceSettingsView.swift` L109-115 (circle), and inline in `NotificationSettingsView.swift` L19-20 and L76, `AccountPreferencesView.swift` L38 and `ProfilesView.swift` L46-48. `LabelAppearancePicker.swift` L139-161 and L246-269 duplicate arrow-key grid navigation.
- `SavedSearchEditor.swift` L29, L58 and L68 use a `"__subset"` sentinel string as a Picker tag. `ReadingSettingsView.swift` L6-7, `NotificationSettingsView.swift` L9, `TriageControls.swift` L48 and `AttachmentLibraryView.swift` L12 store raw strings in `@AppStorage` where `RawRepresentable` enums bind directly.

### Message view

`App/Views/MessageWebView.swift` (416 lines) holds six top-level types. `MessageWebViewWarmup` (L249), `ScrollDirection` (L361), `RemoteContentBlocker` (L374) and `RuleListBox` (L414) are not part of the representable; give them their own files.

WebKit's SwiftUI `WebView` and `WebPage` do not replace the representable yet. `WebPage.Configuration` takes the content rule lists and user scripts through `userContentController`, and the inline-resource scheme through `urlSchemeHandlers`; a `NavigationDeciding` decider covers link policy; `callJavaScript` covers the height measurement; `webViewContextMenu` (macOS 26) passes the link URL, which would carry Open Link, Open Link Behind and Copy Link. What does not carry over is `ContentSizedWebView` (L280): its `scrollWheel` override sends horizontal scrolls to the page and vertical ones to the thread's scroll view, which keeps wide messages scrollable inside a content-sized reader. `webViewScrollInputBehavior` switches a whole input kind on or off, not one axis. Printing is not a blocker, because `ConversationPrintController.swift` L51 prints from its own `WKWebView`. Revisit when WebKit can route scroll input by axis.

### Counts across the app target

Both columns use the same patterns, listed below the table, so the next revision can repeat them. Several first-edition counts were hand tallies and differ from these; the patterns are the reference from now on.

| Pattern | `75374d4` | `58101df` | Replacement |
| --- | --- | --- | --- |
| `Binding(get:set:)` | 60 | 64 | three helpers plus model-provided bindings |
| `.weight(.medium)`, `.weight(.semibold)` or `fontWeight` | 128 | 110 | stay; only regular, medium and semibold (Phase 1) |
| `.caption2` | 35 | 29 | `.caption` on anything read or tapped |
| icon-only `Button` or `Menu` labels | 42 | 37 | `Button(title, systemImage:)` and `.labelStyle(.iconOnly)` |
| `onTapGesture` | 14 | 13 | `Button`, or `.accessibilityAddTraits(.isButton)` where the gesture must stay |
| `GeometryReader` | 13 | 13 | `onGeometryChange`, `onScrollGeometryChange`, `containerRelativeFrame`, `frame(maxWidth:)` |
| `.font(.system(size:))` | 6 | 3 | text styles, or scaled fonts computed once |
| hand-pluralised count strings | 15 | 15 | `^[...](inflect: true)` |
| `inflect: true` | 0 | 5 | |
| `ContentUnavailableView` | 4 | 7 | |
| `@State var` or `let` not private | 6 | 6 | `private` |
| `ForEach(... id: \.offset)` | 9 | 9 | stable identity where rows are edited or removed |
| old `overlay(Shape)` form | 3 | 4 | `.overlay { }` |
| manual `EnvironmentKey` | 1 | 1 | `@Entry` |
| `#Preview` | 0 | 0 | add for the reused components |

```bash
# Run from the repo root; replace REV with the commit to measure.
git grep -E -c 'Binding\(get:|Binding\($' REV -- 'App/*.swift'
git grep -E -c '\.weight\(\.(medium|semibold)\)|fontWeight\(' REV -- 'App/*.swift'
git grep -E -c '\.caption2' REV -- 'App/*.swift'
git grep -E -c 'onTapGesture' REV -- 'App/*.swift'
git grep -E -c 'GeometryReader' REV -- 'App/*.swift'
git grep -E -c '\.font\(\.system\(size:' REV -- 'App/*.swift'
git grep -E -c '"[^"]*\\\([^)]*\) (message|item|file|account|label|thread|attachment|conversation|event|calendar|result|filter|address|draft|day|minute|hour|week|guest|alert|sender|reminder|signature|template)s"' REV -- 'App/*.swift'
git grep -E -c '@State (var|let) ' REV -- 'App/*.swift'
git grep -E -c 'id: \\\.offset' REV -- 'App/*.swift'
git grep -E -c '\.overlay\([A-Z]' REV -- 'App/*.swift'
```

Sum the per-file counts each command prints. The icon-only count matches a `label:` closure, a `Button(action:)` trailing closure or a `Button { } label: { }` whose body is only an `Image(systemName:)` with modifiers; it needs a multi-line match, so a short script does it rather than `git grep`.

No `foregroundColor`, `cornerRadius`, `NavigationView`, `ObservableObject`, `AnyView`, `try!`, `Text + Text` or single-parameter `onChange` remain anywhere. All 36 `@Observable` classes are main-actor isolated.

## Work phases

Order matters. Phases 0 and 1 unblock everything after them. Phase 2 fixes behavior. Phase 3 is the largest user-visible gain. Phases 4 to 6 pay down structure. Each commit touches at most five files and ends with the checks in Verification.

### Phase 0: cleanup, no behavior change

Done in seventeen commits, `035b43c` to `a7801f2`.

- Earlier: `ThreadRow` and `ThreadMenuItems` deleted (`c1b7537`); `MessageListRow` reads `ReadingPreferences.textScaleKey` (`2012eb2`).
- The New Message window takes `Tokens.Layout.composeWidth` and `composeHeight` (`035b43c`).
- `Layout.settingsWidth` is gone, with six more tokens nothing read: `Assistant.settingsHeight`, `Assistant.chatBackground`, `Calendar.viewPickerWidth`, `Calendar.settingsWidth`, `Calendar.settingsHeight` and `Settings.controlWidth` (`035b43c`). The unused `Opacity.pressed`, `Opacity.disabled` and `Motion.slow` stay because they mirror `design_tokens.json`.
- The private `Divider` in `AssistantSidebarLayout.swift` is now `SplitDivider` (`035b43c`). The `sidebarCount` wrapper is gone (`00ae2d2`).
- `Connection.route` stays. `035b43c` removed it, but `AssistantMarkdownTests` reads it, so `a7801f2` restored it with a doc comment.
- Three of the six non-private `@State` properties are private and set from explicit initializers (`45163b5`). `CalendarTimeGrid`'s `frames`, `drag` and `dragCancelled` stay internal, with a comment, because the gesture extension in `CalendarTimelineGesture.swift` sets them. Making them private means moving the drag state into a type of its own (Phase 4).
- The four overlays use the closure form, `AddressAvatar.swift` uses `@Entry`, and the `RichTextEditor` comment gives the reasons it stays on `NSTextView` (`e9cd1b0`).
- `Section` replaces `SettingsGroup` at all 22 call sites, and the type is deleted (`2ce4d00`, `ae1e7d2`, `c3d6aa7`).
- Moves without code changes:
  - `LabelNode` to `App/Mailbox`, `Color(gmailHex:)` to `App/Design/Color+GmailHex.swift` (`9462fe9`).
  - `FlowLayout` to `App/Design` (`c7c36c7`).
  - `searchSuggestions` and `MailSearchSuggestion` to `MailboxModel+SearchSuggestions.swift`; `currentMailboxMessageCount` and `performSwipe` to `MailboxModel+MessageList.swift` (`cfac40f`).
  - `AssistantMarkdown` and `AssistantDiagramLayout` (`5c1397c`).
  - `WorkspaceSection`, `WorkspaceSectionToolbar` and `WorkspaceAssistantToolbar` to `App/Views` (`d821c76`).
  - `MessageWebViewWarmup`, `ScrollDirection`, and `RemoteContentBlocker` with its private `RuleListBox` (`4f63e7a`).
  - `AttachmentChip` to `App/Attachments` (`0df6f44`) and `ProfilePicker` (`e947027`).
  - `CalendarEventChip`, `CalendarWeekdayHeader`, `CalendarMiniMonth` and `CalendarSearchResults` (`5cb13e6`).
- Moved files dropped imports they no longer use: `GmailAPI` and `MessageContent` in `MessageListHeader.swift`, `AppKit` and `UniformTypeIdentifiers` in `AttachmentStrip.swift`. `SidebarView.swift`, `ThreadView.swift` and `MessageWebView.swift` had no unused imports or private members to clear first.
- At `a7801f2`, TernTests pass (330 tests in 53 suites) and a clean Debug build reports one app-target warning, `MessageListRow.swift` L54, as at `58101df`.

### Phase 1: shared helpers

Done in 24 commits, `2b6fbab` to `88def6b`. `c02569c` in that range is the separate UI design review.

- Bindings (`2b6fbab` to `1f1e304`):
  - `App/Design/Binding+Tern.swift` has the planned `isPresent()`, `contains(_:)` and `or(_:)`, plus `isPresent(default:)`, `equals(_:)` for one value of an optional, `selecting(_:)` for radio-style toggles, `negated()`, and `init(_:set:)` for a value with its own write.
  - `Binding(get:` now appears only in that file and in `App/Calendar/CalendarModel+Bindings.swift`, which meets the acceptance check.
  - State that a model stores gets its binding from the model: `SidebarExpansion` (the expanded set in `@AppStorage`), `CalendarModel+Bindings.swift`, `RecurrenceSelection`, `AttachmentLibraryModel+Filters.swift`, `ProfileNotificationSchedule+Editing.swift`, and a setter on `selectedListRowIDs` in `MailboxModel+MessageList.swift`.
  - The calendar delete confirmation is two optionals, one per kind, each shown with `ternConfirm(item:)`.
  - The recurrence control parses the rule once when it opens, so opening it no longer rewrites a rule the provider wrote.
  - `SettingsAsyncToggleRow` shows the new value while `onToggle` runs and drops it when the call returns.
  - Account preference changes show at once and revert if the save fails (`f2a80a3`). No test covers the revert yet.
  - Pickers with an empty choice tag it `String?.none` in place of `""`.
  - Picking a profile schedule's current mode again keeps its custom hours.
  - The filter editor edits plain values in `FilterEditorDraft` (`ab7f2c7`). The size stays a `String`: on macOS, `TextField(value:format:)` commits only on Return or focus loss, so a click on Save could miss a typed size.
  - `ProfileScheduleView` still converts times on each read, so a time zone change shows correctly.
  - `3cf0c4b` renamed `SidebarView.expandedKey` and broke the TernTests build; `ef1897e` fixed the test. Every build since uses `build-for-testing`.
- `ternOutline(radius:style:focus:)` and `ternSurface(radius:style:)` in `Components.swift`, and `SettingsSurface` is gone (`dde15b8`, `6b0b19a`, `6e10ecd`). These outlines stay hand-drawn because they depend on other state: the user bubble in `AssistantMessageView`, `AssistantEmailCard` (contrast before hover and focus), the button style in `AssistantView`, the header borders in `ThreadSummaryView` and `EmailCalendarSuggestionsView`, selection in `AttachmentLibraryFilters` and `AttachmentLibraryRows`, the circle in `SenderAccountLabel`, and the avatar ring in `Components.swift`.
- `NSPasteboard.replaceContents(with:)` in `App/Integration/NSPasteboard+Text.swift` replaces the nine plain-text copies (`b11bd4f`, `adf1d78`). `AttachmentActions` copies a file URL and `OriginalMessageView` copies a message source, so both keep their own code.
- `SettingsErrorLabel` in `SettingsComponents.swift` shows errors in seven panes, all with the circle icon (`cd83a6d`, `a55ea14`). The writing style section keeps its caption-sized message inside its surface.
- `SwatchPicker` serves both color rows (`55b8ade`). `AccountAppearance.palette` holds `Swatch` values with a name and a color, so no separate names list exists to drift.
- `AvatarInitials.from(name:address:)` serves `TernAvatar` and `ContactAvatar`, and `AvatarInitialsTests` covers the input forms both pass (`4d55064`).
- `SearchQuery.quoted(_:)` sits in `MessageContent` beside the parser that reads it back, in place of the planned `GmailQuery`, and a Core test checks the round trip (`40d6cf9`). `RecipientField.editingString` quotes a display name for an address header, not a search operand, so it keeps its own code.
  - Open issue: the parser does not read backslash escapes, so a label name containing `"` does not survive the round trip. Gmail's own handling of escapes is unverified. Addresses can't contain quotes.
    - Closed by `38a946f`: `quoted` adds no escapes and returns nil for a value containing `"`, and label suggestions, address searches and the search scope skip such values.
- `RootView.sceneID` names the mailbox window's scene (`88def6b`).
- Decisions for Phase 5:
  - Weights: no weight tokens and no `.bold()`. `design_tokens.json` defines regular (400), medium (500) and semibold (600), and those are `Font.Weight.regular`, `.medium` and `.semibold`, so the sites already name the token values. `.bold()` would draw at 700. Phase 5 checks that text uses only those three weights and moves the two `fontWeight(_:)` sites into `.font(_:)`. Bold stays on the small glyphs drawn on a fill (`SwatchPicker`, `LabelAppearancePicker`, the `EmailCalendarSuggestionsView` badge), and the empty-state symbol keeps `.light`.
  - Empty states: `TernEmptyState` keeps its API and is rebuilt on `ContentUnavailableView`, so the 24 call sites stay as they are and look like the seven that already use the system view. `fillsSpace: false` and the width cap need checking on the rebuilt view. The no-results case in `SettingsView` becomes `ContentUnavailableView.search(text:)`.
- At `88def6b`, TernTests pass (331 tests in 54 suites), Core tests pass (516 tests in 87 suites), and a clean Debug build reports one app-target warning, `MessageListRow.swift` L54. The first full TernTests run failed `mailboxExpansionKeepsSidebarViewportAndInboxInPlace`: from the fourth mailbox on, the sidebar viewport was 59 points shorter. The test alone, its suite and a second full run all passed, so it is recorded as a timing flake.

### Phase 2: correctness

Done in nine commits, `23bd6f3` to `16d0572`.

- `MessageListRow` copies `textLeading` into a local before the `alignmentGuide` closure, which is `Sendable` (`23bd6f3`). The app target now builds without warnings.
- The event editor keys guests by address and alerts by an `EditableReminder` row with its own `UUID`, so removing a middle row keeps the other rows' toggles and pickers (`5d7bfb4`). The index-based `.id` is gone, and `id: \.offset` sites fell from 8 to 6.
- `CalendarView` keeps one `HSplitView` and leaves the sidebar out of it below the compact width, which `onGeometryChange` reports, so the grid keeps its state and scroll offset (`090ca10`). Its `GeometryReader` is gone, which leaves 12 in the app.
  - Deviation: the 8 AM start is a point-based `ScrollPosition` that `CalendarTimeGrid` holds, not the model. In a test harness on macOS 26, `ScrollPosition(id:)` never applied its first position, and after a user scroll the binding reported `isPositionedByUser` with no point, so a model-held position could not bring back the user's offset after a rebuild. Keeping the split is what keeps the offset. `CalendarLayoutTests.timeGridOpensAtEightInTheMorning` checks the start.
  - `CalendarView.swift` is over 300 lines. Rule 9's cleanup found no dead code or unused imports, so no separate commit came first.
- `AttachmentLibraryCollection.select` and `moveSelection` take modifiers as parameters (`4dc05d1`). A click passes the Shift and Command keys held at that moment, which `onModifierKeysChanged` tracks. Arrow keys pass Shift only, and the accessibility default action passes none. Nothing reads `NSEvent.modifierFlags` any more.
- `ReceivedAttachmentsView` (`eeed593`):
  - Quick Look opens the clicked file as soon as it downloads, then adds the others in message order while the panel stays open.
  - `InFlightTasks` shares a running download between the preview, Save All and the chips. `InFlightTasksTests` checks that a second request waits for the first, which covers Phase 6's shared-download test.
  - Save All skips failed downloads and says "Saved all N attachments.", "Saved X of N attachments." or "Couldn't save the attachments. Try another folder."
- `ThreadView` gives each message the one `.id(message.id)` that its `scrollTo` calls use (`54d42f2`). The account-qualified inner id did nothing: `MainView` already rebuilds `ThreadView` per thread key, and the key carries the account.
- `AssistantMailPaneSizing` (`59679bc`, `e384712`, `16d0572`):
  - The test: a harness that mirrors `MainView`'s columns ran on macOS 26 with `setPosition` disabled, at 960 and 1280 points, after dragging both columns. The column widths alone narrowed both panes to their minimums, and at 960 navigation collapsed without resizing the window. Closing restored the dragged widths at 1280, but at 960 the list fell back to its minimum.
  - So the helper now only restores. It saves the divider positions on open and sets them again after close. An attempt that runs before the split widens waits for the next layout pass instead of clamping the list and spending its retries, and `restoreWaitsForTheSplitToWiden` fails without that wait. In the harness, 12 of 12 closes restored the dragged widths.
  - On macOS 26 the list column's frame starts at x 0, under the sidebar, so the helper saves each pane's `maxX`, which is the divider position, in place of its width.
  - The inset is still needed. `MainView` clips the mail columns so a split wider than its frame never draws over the assistant, and any clip or mask drops the split's toolbar safe area. Unclipped, the split had 52 points of top safe area; clipped, it had none and the first rows sat under the toolbar. `ClippedSplitToolbarInset` now owns the measurement, and `SidebarLayoutTests` checks that the rows clear the toolbar.
  - `EnclosingSplitDivider` finds the divider for the probe and for `DividerGrabView`. The probe is `MailColumnProbe`, in its own file.
  - Fixed in `e0410b9`: with the assistant open below about 950 points, the list, reader and divider need 629 points, more than the mail area has, and the split overflowed that area centered. At 720 points the list's first 115 points sat past the window's left edge; with the assistant closed, 48.5 points of the sidebar did. `MainView` now gives the mail content `frame(width:alignment: .leading)`, so the clip cuts any overflow from the trailing side. `SidebarLayoutTests.workspaceKeepsFirstRowsAndMailSearchVisible` checks the leading edges of the split and its first rows at 720 points, then opens the assistant from its toolbar item and checks 960 and 720. Without the alignment it fails at -48.5 and -115 points. The test runs `WorkspaceView` in the test host, not the app on screen.
  - With the assistant closed, the reader fits at 720 points: UI design review item 2 (`0b1477e`) hides the sidebar below the three-column minimum, and the same test checks that every column lies inside the window there and that the sidebar returns at 1280.
  - Still cut: with the assistant open at 720 points, the assistant keeps its 320-point minimum, which leaves the mail area 399 points. The list's 308 take most of it, and about 90 points of the reader show.
  - Also open: saved positions that stay out of reach, for example after the window shrinks while the assistant is open, stay pending and apply on a later widening.
- Done earlier: the Signatures pane no longer writes on open, and a lower cache budget asks before trimming (`c5ebd40`).
- Not checked: the Accessibility Inspector audit and VoiceOver pass that Verification lists for this phase, and the changes in the running app.
- At `16d0572`, TernTests pass (334 tests in 55 suites) and a clean Debug build reports no warnings in `App/`. Its three warnings are in `Packages/Core` (`PrintDocument.swift` L23 and L25, `DraftImport.swift` L85), outside this plan.

### Phase 3: performance

Profile first with the Instruments SwiftUI template and record body counts for the three scenarios in Acceptance, so each commit can show the before and after.

- Calendar: stored `start`, `end`, day key and color on `CalendarDisplayEvent`; one per-day bucketing pass replacing `events(on:)`; `days` computed once per body; `Date.IntervalFormatStyle` and `Date.FormatStyle`; `presentation` computed once per row; a static time zone table for the picker.
- Assistant: `AssistantMessage: Equatable` and `.equatable()` rows; cached markdown blocks, diagram layout and decoded avatars; coalesced `textDelta` commits; stored `hasMessages`; the thread summary hash computed once; email and source dedup in the model.
- Compose: avatar rasterized once in the model; coalesced `RichTextEditor.publish`; gated `configureAvatars`; recipient text published on tokenize; cached signature render; drag attachables resolved once per drag.
- Mail: scaled fonts, parsed sender and resolved labels precomputed for `MessageListRow`; the parsed sender stored on `MessageDetail` for `MessageView`; decoded account colors and compact marks stored for the thread list and sidebar; sidebar outline and expansion set on the model; pagination from `onScrollGeometryChange`; `MailWorkspaceColumns` stores views; the five `refreshAccess` relays become one.
- Attachments and settings: filter chips built once; type, icon and parsed sender cached per row; `AccountAppearance` decoded once; `savedHTML` memoized; `MailboxSwitcher` options built once; `validation`, `problem`, `blocked` and `matches(search)` hoisted to `let`; `OriginalMessageView` decoded once in `load()`.

### Phase 4: view structure

- `ThreadView` moves its flows into `ThreadReaderModel` and splits into `ThreadHeader`, `ThreadMessageList` and `MessageView` files.
- `MainView` extracts `MailWorkspaceView`, a tested shortcut dispatcher and one `NoticeView` placement. The window `GeometryReader` becomes `onGeometryChange`.
- `AssistantConversationView` replaces its readers, preference key and bottom sentinel with `onScrollGeometryChange`, `scrollPosition(_:)` and `onScrollPhaseChange`.
- `CalendarEventEditor` holds one `values` struct and one child view per section, and the calendar sheets size with `presentationSizing` instead of reading `NSApp.keyWindow`. `CalendarView`, `CalendarManagementView`, `ComposeView`, `AssistantMessageView`, `AssistantView` and `AssistantSettingsView` extract their computed sections into child views.
- One source of truth each for the calendar sidebar selection and the attachment library search text.
- `RecurrenceRule` moves to Core with tests; the drag math joins `CalendarInteraction`; `RecipientSuggestionLoader` and `MarkdownAutoFormat` move to Core; the three compose settings panes share one model.
- Remaining `GeometryReader` uses drop to three or fewer, each with a comment saying why.
- Enum-typed selections replace the `"__subset"` sentinel, the string-typed recurrence selections and the raw-string `@AppStorage` values.

### Phase 5: accessibility and design

- Icon-only controls become `Button(title, systemImage:)` or `Menu(title, systemImage:)` with `.labelStyle(.iconOnly)` (37 sites).
- `onTapGesture` selection in `FavoritesView`, `SidebarView` and `MailboxSwitcher` becomes a `Button` or a list primary action.
- `.caption2` audit: `.caption` for any text that is read or contains a control (29 sites). The calendar sites label decorative text and can stay.
- Hand-pluralised strings use inflection (15 sites), starting with the ones that read "1 messages".
- `ternAnimation(value:)` replaces the ad hoc reduce-motion check in `SidebarView`. Over-budget and unread states gain a non-color cue under `accessibilityDifferentiateWithoutColor`.
- The weight decision from Phase 1 is applied app-wide, opacity literals use `Tokens.Opacity`, and the `.font(.system(size:))` sites use text styles or the scaled fonts.
- The empty-state decision from Phase 1 is applied to the 24 `TernEmptyState` call sites and the seven `ContentUnavailableView` sites.

### Phase 6: previews and tests

- `#Preview` for `MessageListRow`, `ThreadHeading`, `LabelChip`, `CalendarEventChip`, `AssistantMessageView`, `AttachmentChip` and the Settings components, fed by the Debug fixtures in `App/Debug/AvatarAuditFixtures.swift` and small inline records, with `@Previewable` where a preview needs state.
- Tests in `TernTests` for the binding helpers, the shortcut dispatcher, calendar bucketing, the editor row identity regression and shared attachment downloads. `AssistantSidebarLayoutTests` and `AssistantScrollTrackingTests` already exist and must keep passing. Core tests for `RecurrenceRule`, `RecipientSuggestionLoader` and `MarkdownAutoFormat`.

## Acceptance

- No body in `App/` parses, hashes, rasterizes, creates a formatter, or filters a collection per cell. In the counts table, the `Binding(get:set:)`, icon-only, `onTapGesture`, `.font(.system(size:))` and hand-pluralised rows read zero, or each remaining site carries a comment.
- `Binding(get:set:)` appears only in `Binding+Tern.swift` and in model methods that return bindings.
- `GeometryReader` appears at most three times, each commented.
- The Debug build reports no warnings in `App/`.
- Every control has a text title. Keyboard and VoiceOver selection in the attachment library never applies a shift or command range by accident.
- Streaming a long assistant reply re-evaluates only the streaming row (Instruments body count stays flat for the other rows).
- Dragging an event in the week and month views runs one bucketing pass per frame, not one filter per cell.
- Typing in the compose subject does not re-render the From avatar or redraw the recipient token fields.
- Removing a middle guest or alert in the event editor keeps the remaining rows' state.
- Clicking one received attachment opens it without waiting for the others, and Save All says how many files it saved.
- `xcodebuild`, `swift test --package-path Packages/Core` and the `TernTests` target pass after every commit.

## Verification

```bash
xcodegen generate
swift test --package-path Packages/Core
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build build
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build test -only-testing:TernTests
```

To check the warnings criterion, build into a fresh derived-data folder so every file compiles, then list the app's warnings:

```bash
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath /tmp/tern-warnings build 2>&1 | grep -E '/App/.*: warning:' | sort -u
```

For Phase 3, profile with the Instruments SwiftUI template before and after each commit, recording body evaluation counts for: streaming a 2,000-word assistant reply; dragging an event across a week; typing 50 characters into a compose subject with three recipients. Record the counts in the commit message.

For Phases 2 and 5, run the Accessibility Inspector audit on the main window, the compose window and Settings, then check VoiceOver on the thread list, the sidebar and the attachment library, and check the app with Reduce Motion and Increase Contrast on.
