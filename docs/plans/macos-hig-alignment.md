# Tern macOS HIG alignment

## Scope

Bring every surface of the app in line with Apple's macOS Human Interface Guidelines: menu bar, keyboard, windows, toolbar, sidebar, pointer, notifications and system integration. The base is `main` at `b76146f` on 2026-10-31. The audit used the `macos-design-guidelines` checklist and three read-only sweeps of every view in `App/`. Earlier design passes fixed appearance; this one fixes interaction. The work ran on the `hig/integration` branch, which merged `main` back in as `main` moved.

## Decisions

- Deployment target rises to macOS 26.0 for the app and `Packages/Core`. Xcode 26.3 ships the macOS 26.2 SDK, so 26 is the ceiling.
- System integration is fully in scope: Share, Services, Dock menu, Core Spotlight, Handoff, App Intents and the AppleScript Standard Suite.
- Settings keeps its shell; the work there is behavior.
- Phases ran back to back with a verification and a commit per phase and no approval gates between them.

## What already conformed

Tokens for every spacing, radius and surface; Reduce Motion through `ternAnimation`; Apple Mail shortcuts with state-dependent titles; native multi-selection, swipe actions and selection context menus in lists; `.cancelAction`/`.defaultAction` on sheets; the remote-content banner and dark-mode adaptation of authored HTML; grouped notifications behind an explicit permission control; accessibility labels on every icon-only button.

## Results by phase

### Phase 0: baseline and target (`d615e5c`)

App and Core target macOS 26.0 (tools version 6.2 for `.v26`). The three `#available` branches went (toolbar item hiding, swipe action pairs, Writing Tools) and the deprecated `activate(ignoringOtherApps:)` call was replaced. Core: 515 tests in 87 suites. Hosted: 317 in 52.

### Phase 1: tokens and helpers (`15d5cb8`)

`Tokens.Status` (error, warning, success, star, important) and `Tokens.Opacity` (hover, pressed, tint, disabled) draw from system colors so Increase Contrast applies. Layout tokens for the compose label column, editor minimum height, list avatar and settings pickers end the borrowing of unrelated values. The main window minimum is 720 by 480 so two windows tile on a 13-inch display. `ternHover`, `ternResizeCursor` and two `ternConfirm` helpers back later phases. `ShortcutCatalog` lists every command with a key equivalent, its menu and its scopes; `ShortcutCatalogTests` fails when two live commands share keys. New Label moved from ⌥⌘N to ⌃⌘N, ending its clash with New Event.

### Phase 2: menu bar and keyboard (`edc3a13`)

File: New Chat, New Event, New Label, Open Conversation, Print… and Export as PDF…; Add Account… moves to the app menu. Edit: Find… for the calendar and attachment library. View: `ToolbarCommands`, Show Viewing Pane, Density, Expand All and Collapse All. Mailbox: Mark All as Read, Empty Trash, Delete All Spam, Delete Forever. Message: Forward as Attachment, Report Spam, Mark as Important, Copy Link, Open in Gmail, and counted Archive and Trash titles. Calendar menu: Today, Go to Date…, the display modes and the panels. Go: Mail, Calendar, Attachments (⇧⌘1…3). Window: Tern ⌘0 and Assistant ⌥⌘A, which `3a27dac` later moved onto the scenes' own items. Help: Keyboard Shortcuts ⌘/. Focused scene values publish the reader, calendar, assistant and attachment toolbar to the menu bar. Calendar single keys follow the mail setting. ⌘⌫ in a text field deletes to the line start. Return cancels the permanent-deletion review and Esc keeps the app open in the quit alerts.

### Phase 3: window shell, toolbar, sidebar (`44a0f04`, `b0d6155`)

Search moved from the message list into the window toolbar as one field that follows the active section (mail, events, attachments); ⌥⌘F and Find focus it. Sidebar mailbox rows gained context menus (Mark All as Read, Empty Trash…, Delete All Spam…, Add or Remove from Favorites) and favorites reorder by drag. Column visibility persists. The conversation window shows the subject and participants, carries the shared triage and reply items and has a minimum size. A Dock click reopens the main window, the Dock menu offers New Message, Check for New Mail, Inbox and Calendar, and calendar notifications open the window through `openWindow`. The mail triage items hide instead of greying out while Calendar or the library shows. A shared `ConversationDragItem` with an exported UTType carries conversations between the message list, the sidebar and the calendar grid.

Three later commits finish the shell. `e478e97` scales the sidebar's mailbox, account and label symbols with the Sidebar icon size setting, and Medium, the default, keeps the earlier sizes. `55d09a4` collapses the sidebar while the window is narrower than the three column minimums, about 818 points, and brings it back when there is room. A sidebar the user shows or hides stays that way. `dc69a8a` adds fixed toolbar spaces, so triage, replies, search and the assistant each get their own capsule, and moves More to the end of the triage group. The last merge with `main` replaced `55d09a4`, `dc69a8a` and the section picker decision below with `main`'s versions from its UI design review (see Merges with main).

Deviations, with reasons:

- Native sidebar toggle not adopted. With a customizable autosaved toolbar, AppKit asserts on restore ("Cannot unregister separator item") and, with two windows in the toolbar family, on "Duplicate items" for the toggle. Items declared in the sidebar column trip the same assertion on `splitViewSeparator-0`. The toolbar keeps one `workspace.sidebar` item; View ▸ Show/Hide Sidebar (⌃⌘S) drives it through a focused value.
- `.searchable` not adopted. On macOS 26 the system search item inside a customizable toolbar puts SwiftUI's toolbar bridge in a layout loop and the window never finishes opening. `WorkspaceSearchToolbar` is an `NSSearchField` item; `.searchSuggestions` and `.searchScopes` are therefore not used and the message-list header keeps its suggestions.
- Section picker: a `.principal` segmented control pushed search and the assistant button into the overflow at 1325 points and below, and a leading pop-up overflowed the search field at 960. Mail and Attachments switch sections from the sidebar's Library rows and the Go menu; the pop-up shows in Calendar only, where there is no mail sidebar.
- `Tokens.Layout.searchWidth` went from 320 to 200 points so search and the assistant button both fit at 1280.
- `SplitDividerHandle` kept (it already sets the resize cursor); `isCompact` toolbar switching kept; the `.inspector` spike skipped (the panel stays, the calendar copy is resizable).
- `DisclosureGroup`/`OutlineGroup` not adopted in the sidebar because a disclosure row cannot be selected on macOS.
- `SidebarLayoutTests` waits for the first layout (rows and toolbar inset) instead of a fixed 200 ms; under load the first layout takes 200–500 ms.
- Toolbar spaces ignore `hidden(_:)`, so a space stays when the items beside it hide. The mail items come before the calendar and library items (`14625f7`), which puts the two mail spaces ahead of those sections' controls, in the open part of the toolbar where they don't show. More ends the triage group again, as it did in `dc69a8a` (`4dd0059`). Narrow windows fold that group into one menu, and while More had a group of its own, its space stayed there and made the gap before Search twice as wide as the others.

### Phase 4: message list and reader (`b71eb0e`, `079a259`, `1bee764`, `2cdb19b`)

List: Delete runs the action chosen in Settings; double-click and Return open through the selection context menu's primary action; Space previews the first attachment or toggles read; rows drag as conversations and drop on sidebar labels and mailboxes through the action queue (`MailboxModel+Drop.swift`, `ConversationDropTarget.swift`); each row is one accessibility element whose label reads unread state, sender, subject, date, count and star; dates, counts and chips scale with the text-size setting through one `scaledFont` helper; label chips are `TernBadge`s; slash titles became the state-dependent menu titles. The saved-search editor is a popover. `c1b7537` removed the unused thread row and menu types in a commit of its own. `2012eb2` moved the list to the inset style with rounded selection: the unread dot and avatar are centered, dates use monospaced digits, the hollow star shows only on hover or selection, and label chips are capsules.

Reader: context menus on headers and cards (Reply, Reply All, Forward, Mark Unread from Here, Star, Copy Link, Show Original, Print) and on label chips (Remove Label, Show Label); a click anywhere on a collapsed header expands it; ⌘↑/⌘↓ move between messages, ←/→ collapse and expand, Space pages the body; Edit ▸ Find… (⌘F) opens a find bar over the reader that steps through the message web views (`ReaderFindBar.swift`); Search Mail stays ⌥⌘F. Attachments preview as one Quick Look set so arrows page, drag out as files, and offer Share and Show in Finder. Print and Export as PDF run as window sheets, named after the subject, with the shared paper size. Show Original opens its own window with Copy and Save… as sheets. Web links keep one decision point: `mailto:` and `tern:` links route inside the app, web links go to the browser; the link context menu offers Open Link, Open Link Behind Tern and Copy Link. The hovered URL shows in a bottom overlay; the light-background button appears only in Dark; recipients, dates and banner buttons use `.subheadline` and `.callout`.

Deviations: no `.eml` drag export from the list because raw bytes come from the network, not the cache (Show Original ▸ Save… covers it); "Open Link in New Window" became Apple Mail's "Open Link Behind Tern" since Tern has no in-app browser; Quick Look downloaded all of a message's files before showing the first so arrows could page, until `eeed593` on `main` made it show the clicked file first and add the rest as they arrive; `TernBadge` text does not follow the text-size setting. Pre-existing and untouched: moving from Trash through `LabelQueue.move` removes INBOX rather than TRASH, so drop-to-Inbox uses `editLabels`.

### Phase 5: compose (`58f9678`, `9d671a2`, `bdc8ceb`, `57fe9cd`, `87ebe2d`)

The close button's dot shows only when closing would save changes Gmail doesn't have, so an untouched or blank message never shows it. The link popover reads the selection when it opens and anchors to it. Attachment chips take focus, open Quick Look on click and Space, page through the draft's files like the reader, and drag out under their own names; copies are written off the main thread and removed with the window. Their context menu offers Quick Look, Show in Finder and Remove. Recipient tokens get a menu with Copy Address, Edit, Remove and Hide from Suggestions, and Edit keeps names that contain commas intact. Pasted or dropped HTML goes through the importer drafts already use, because AppKit reads HTML with WebKit, which can load remote images. HTML with no list, link or styled text pastes as plain text, so code keeps its indentation and Markdown paste still works. VoiceOver announces the highlighted recipient suggestion. Continuous spelling and grammar checking are on, the serif font uses the system `.serif` design, the Cc and Bcc buttons read "Add Cc Recipients" and "Add Bcc Recipients", Discard Draft sits at the far end from Send, and the error alert has a title with the detail as its message.

Deviations: the plan's "Add to Blocklist" token item is named Hide from Suggestions, as in Settings, and its error alert reads "Can't Hide This Address". Not checked by hand: dark mode, the chips, VoiceOver, the popover anchor and paste in the installed app.

### Phase 6: calendar (`d8f74a1`, `10fafa3`, `beefead`, `e2dc2e2`)

The in-content header went. A Calendar toolbar (`calendar.navigation`, `calendar.today`, `calendar.mode`, `calendar.newEvent`) shows only while Calendar is active; the mode switcher is a titled menu so the search field still fits at 960 points, and at 720 the search field moves into the overflow while navigation stays. The display mode persists. The calendar sidebar is a `List(.sidebar)` with the mini month, tinted calendar rows and the Today agenda. Pointer: hover on chips, agenda rows and day cells; resize cursors on grips with 8-point hit areas; grab pointers during moves. Agenda, schedule and search rows drag out as `.ics`; the grids accept dropped conversations and open the editor prefilled through the extraction service. Keyboard: ↑/↓ walk the day's events, ←/→ step by day or week, ⌥←/⌥→ change the period, Return edits; undo runs through the window `UndoManager`, shared with mail. Sheets size to content with a minimum; the time zone is a searchable picker; weekday names and working hours come from the calendar and formatters. Guest-bearing deletes confirm; recurring deletes keep the three-way dialog. Manage Calendars… opens Settings on the Calendar pane (the sheet is gone). Export and print run as window sheets with the shared paper size. Calendar colors keep Google's hue but resolve per appearance and contrast.

Deviations: grid cards are not SwiftUI drag sources because a drag source would fight the custom move and resize gesture; the toolbar mode switcher is a `Menu` holding an inline `Picker` because a bare menu-style picker rendered blank in the toolbar. Drag create, move and resize were not re-exercised by hand in this phase (the gesture code did not change); the toolbar customization palette was not exercised.

### Phase 7: attachment library (`86b0018`, `bbac132`, `cd88a02`, `57e6506`, `44cc61c`, `18e2cb4`)

The header tile that repeated the window title is gone. While the library shows, the window toolbar carries a List and Grid switch and a Sort By menu, and the window's search field searches the library; the layout choice persists. In narrow toolbars both controls fold into one View Options menu (`1d47301`). The content keeps the category shortcuts and the Filters popover in a slim bar, and the popover sizes to its content with `PopupHeader` and `PopupFooter`. `Tokens.Opacity` gained `wash` (0.08) and `outline` (0.5). The source-email sheet became Open Conversation in New Window. The reader and the library share `AttachmentFileItem`, so files drag out to Finder, Compose and other apps, a drag that starts on a selected file carries the whole selection, and each file downloads only when the receiver asks for it. The context menu adds Share, and Show in Finder for copies this window saved or opened in Downloads; the download cache is pruned, so it is never revealed. Double-click and Return open files in both layouts, Space opens Quick Look, and Quick Look pages through the selection. Rows and cards offer the same commands to VoiceOver as actions.

Not checked by hand: the grid in Dark, dragging out, Share, Show in Finder, Quick Look, the keyboard paths, toolbar customization and the row context menu in the running app.

### Phase 8: assistant (`d824b59`, `39763ca`, `741bd9c`, `e76be6f`, `1bfd71b`, `485d390`)

The Assistant window leaves full screen to the system's green button and View ▸ Enter Full Screen, and no longer draws its own button or edits its collection behavior. When detached, New Chat and Assistant Settings move from the sidebar header into the window toolbar and the model name shows as the subtitle. Esc closes the sidebar when the composer is empty and no marked text is pending. The sidebar width persists (`assistantSidebarWidth`), and so does the calendar copy's (`e0bcd42`). Replies get Copy, Copy as Markdown, Copy as Plain Text and Retry. Copy writes rich text with a plain-text fallback and ignores the display limits, so a long reply copies whole. Code blocks get Copy, and mail cards get Open, Open in New Window and Copy Link. Disconnect, Clear Chat, an access change while a chat exists and turning off writing-style learning confirm through `ternConfirm`. Assistant settings are grouped sections with plain rows, and the sheet's Done answers Return and Esc. The composer, header buttons, suggestion rows, mail cards and the sign-in button use the system focus ring. Header labels use Title Case, the card star uses `Tokens.Status.star`, and the unused settings introduction went (`52f6586`).

Deviations: Open Full Screen stays in the sidebar menu and enters full screen once. Not checked in the running app: Esc with the composer focused, full screen, context menus on selectable text, the focus ring on the plain text field, and Settings ▸ Assistant in Light and Dark.

### Phase 9: settings and accounts (`c5ebd40`, `660090f`, `e5752d2`)

The selected pane persists and follows a defaults key other windows can set before opening Settings; a Calendar pane hosts calendar management. Done buttons answer Return as well as Esc. Discarding failed changes, unblocking a sender, Trim Now, the auto-trim after a budget change and enabling Permanent Deletion confirm through `ternConfirm`. Rows are `LabeledContent` in grouped `Form`s; the segmented sub-tabs became sidebar rows under their sections, so navigation has one level, and the hand-drawn dividers that rendered as empty rows went. Gmail Signatures and Account Nickname apply live with a shared debounce (`LiveApplyScheduler`) and a pending indicator; the Vacation Responder keeps Save and guards unsaved changes on pane switch and window close. Accounts reorder by drag. The Dock badge has a switch (`NotificationPolicy.dockBadgeKey`). Sizes use `ByteCountFormatter`; the keyboard-shortcuts note opens the help window.

Deviations: the umbrella `.accounts` and `.composing` destinations went with the sub-tabs; `SettingsGroup` became a plain `Section` wrapper, which `main` later deleted (see Merges with main); `SettingsTabBar` and `SettingsRowLabel` were deleted; the four Gmail panes share `GmailSettingsHeader`. Not covered: the unsaved-changes guard does not fire when switching accounts inside the Vacation pane; confirmation sheets and the filter editor could not be exercised in the synthetic app (no Gmail settings client).

### Phase 10: notifications, Dock, status item (`58101df`)

Notification categories register once at launch. New-mail notifications carry every triage action plus Reply, with the action chosen in Settings first. Reply opens a reply window, so the signature, quoted text and Undo Send still apply. Alerts and Tern's new-mail sound stay quiet while Tern is frontmost and the conversation is on screen, in the mailbox or in a conversation window. The menu bar count opens a menu with the Inbox, counts per account, Check for New Mail, New Message and Open Tern. The "Message sent" and "Mail moved to the Inbox" notices went: they offered no Undo, and the send sound and the list already confirm them. Notices that offer Undo stay.

Deviations: there is no text-input reply action, because a reply typed in the notification would skip the signature, quoted text and Undo Send. The Dock menu does not list recent drafts. Not checked by hand: the status menu's appearance, whether the quiet-alert check requires the main window to be visible, and the notification actions end to end.

### Phase 11: system integration

Share and Services (`9a505ed`, `fa86763`, `4e60fa2`, `e877fdc`): a message's More menu and its card's context menu share the message as an `.eml` file. Tern fetches the raw bytes from Gmail only when a service asks for the file and names each file after the subject. Message ▸ Share… shares the selected message, else the message with selected text, else the newest message that isn't a draft, and is disabled with no conversation selected. Every calendar event menu comes from `CalendarEventMenuItems` and adds Share, which sends the occurrence as `.ics`. Other apps' Services menus get New Tern Message with Selection, which puts the text in a new draft's body, and New Tern Message to Address, which fills To from addresses separated by commas, semicolons or new lines. A service only opens a draft; it never sends. `e877fdc` keeps the message's share item Sendable by storing the preview's title instead of the preview.

Spotlight, Handoff and restoration (`21e8e19`, `6c4b765`, `e1f14da`, `d2c8a21`, `7fb16c6`): Reading ▸ Privacy ▸ Show Mail in Spotlight is off by default. When it is on, each account's Inbox and most recent conversations, up to 2,000, become one item each with the subject, Gmail's snippet, the latest sender's display name and the last message date. Addresses and bodies are never indexed. The index rebuilds at launch, follows each sync, and is removed on cache reset, sign-out or turning the setting off. A result opens through the mail URL router, even with every window closed, and Settings search finds the setting. The reader advertises `dev.tern.mail.conversation` and the calendar `dev.tern.calendar.day`, for Handoff only; their web pages are Gmail and Google Calendar on the web. The conversation's web address includes the account's email address, and Handoff sends it only to the user's own devices. The main window reopens the last mailbox after relaunch through `@SceneStorage`, which follows the system's "Close windows when quitting an application" setting. The conversation is not reopened, so a relaunch never marks mail read.

Shortcuts and AppleScript (`c519fea`, `9315aeb`): Shortcuts and Siri can start a new message, check for new mail, open a mailbox, search mail and snooze the selected conversations; four of these ship as App Shortcuts. The scripting dictionary includes the Standard Suite, so a script can make a new outgoing message with a subject, content and recipients, which opens in a compose window. No command sends mail, and conversations and messages stay read-only.

Not confirmed: `mdfind` found no Tern items after indexing was turned on in the Debug build, so Spotlight indexing is unverified. Services, the card and calendar Share items and the `.eml` contents were not run end to end; Message ▸ Share… was checked through accessibility. Handoff routing was tested in code, not between devices. AppleScript was not run against the installed app. `NSHumanReadableCopyright` stays empty because no copyright line was given.

### Phase 12: sweep (`e4caf5e`, `1ba5751`, `7ed2950`, `2ee2864`, `f7b3ff9`, `8bfe57f`)

Errors, warnings and outbox states use `Tokens.Status`, and error text that relied on color alone gets a warning icon. The loading screen uses the window background, like sign-in. Popover titles, buttons, picker items, empty-state titles, the summary menu and the single-key shortcut names use Title Case; Assistant Settings… ends in an ellipsis because it opens a sheet. Swipe buttons say Read or Unread and Star or Unstar for the row, and Settings lists swipe actions by their menu names. The saved-search editor says "Search terms" and links to Gmail's search operators. With nothing selected, Message ▸ Snooze is a plain disabled item, because a disabled submenu still opens from the menu bar, and Share… is disabled. Mail notices show while the attachment library is open. The sidebar's sync status became a safe area bar. The last merge took `main`'s version of it, which adds a hard scroll edge.

Deviations: `legibilityWeight` was skipped because macOS has no Bold Text setting. Swipe buttons keep short verbs instead of the full menu titles. Settings section headers stay sentence case. Not checked in the running app: Message ▸ Snooze and Share… with a conversation selected.

## Merges with main

Other sessions refactored SwiftUI views and fixed defects on `main` while this work ran. `main` fast-forwarded to this branch once, at Phase 10 (`58101df`). After that the branch merged `main` back in 13 times, each by exact hash.

- `7f64b2f` merged `main` at `a7801f2`. Shared views moved to their own files and `SettingsGroup` was deleted, so the assistant settings panes use `Section`. `AssistantMarkdown` keeps the unbounded parse that copying a reply uses, and `AttachmentStrip` keeps its drag item and the imports it needs.
- `b34ea5e` merged `main` at `e3b9935`. Binding helpers and `isPresent()` replaced hand-built bindings, and `SidebarExpansion` replaced `SidebarView.expandedKey`. The library's source sheet, which `main` had rebound, stays removed in favor of Open Conversation in New Window, and the compose alert keeps its title and message. `e3b9935` left `SidebarLayoutTests` writing to the removed key, so the merge points the test at `SidebarExpansion.storageKey`; the stored format did not change.
- `152c495` merged `main` at `29cd04b`. Calendar, list, menu and settings controls bind through the model and the new `Binding(_:set:)` helper. The assistant's account access and writing-style switches keep this branch's form rows, which ask before clearing a chat or deleting a learned style, and now use that helper; `main`'s separate trailing switches were dropped.
- `329d059` merged `main` at `ab7f2c7`. Filter fields became plain values. The attachment filters popover keeps this branch's layout and status colors with `main`'s day and megabyte bindings.
- `33e7e90` merged `main` at `adf1d78`. It brought `ternOutline`, folded `SettingsSurface` into `ternSurface`, moved text copying to `NSPasteboard.replaceContents(with:)` and added the UI design review. The assistant composer, suggestion rows and code blocks keep the system focus ring, so they take `ternOutline` without a focus color. `c0e8190` then moved this branch's two copy sites, Copy Link on the assistant mail card and Copy Address on recipient tokens, to the helper.
- `448f1d6` merged `main` at `5d7bfb4` without conflicts. It brought `SettingsErrorLabel`, a shared `SwatchPicker`, one avatar initials helper, quoted search operands, `RootView.sceneID`, keyed guests and alerts in the event editor, and the list separator inset.
- `2cd0c5a` merged `main` at `54d42f2`. The calendar keeps one split view when the window crosses the compact width and opens the day at 8 AM. Attachment cards take selection modifiers explicitly, Quick Look opens the clicked file first, and Save All reports how many files it saved. Each reader message has one identity. The library grid keeps this branch's drag source, double-click open and VoiceOver actions with `main`'s explicit modifiers.
- `ef1fb73` merged `main` at `59679bc`. The clipped split's toolbar inset moved into `ClippedSplitToolbarInset`.
- `d1b6ae1` merged `main` at `e384712`. Pane sizing restores only the divider positions it saved.
- `3f0859b` merged `main` at `16d0572`. The mail column probe moved to `MailColumnProbe`, XcodeGen regenerated the conflicting project file, and this branch's narrow-window test now looks for the renamed probe.
- `623124d` merged `main` at `d3c5136`, which only adds notes to the SwiftUI plan and the handoff log.
- `7fef621` merged `main` at `8360797`. `e0410b9` aligns the mail content to the leading edge of its frame, so a split wider than the mail area runs under the assistant or off the trailing edge, never off the leading edge. `SidebarLayoutTests` keeps this branch's sidebar collapse checks at 720 points and adds `main`'s leading-edge checks there and, with the assistant open, at 960 and 720 points.
- `6b977fc` merged `main` at `a1fd65a`, which carries the UI design review's implementation and gives `SearchQuery` in Core a scope. Where both branches had fixed the same review item, the merge keeps `main`'s version; the next section lists them. `SidebarLayoutTests` now checks `main`'s sidebar collapse at 720 points and its return at 1,280. This branch keeps the reader's Handoff activity, the stored mailbox, the notice overlay, the assistant's persisted width and system focus ring, the Spotlight keywords in Settings, and its Title Case strings. After the merge, the library's layout and sort controls pushed Search into the overflow menu at 720 points. `1d47301` folds them into one menu below the compact toolbar width, and `SidebarLayoutTests` checks the library toolbar at 1,280 and 720 points.

## UI design review

`docs/plans/ui-design-review.md` lists 26 suggested changes from a separate audit of the running app. `main` implemented every item except 4, which did not reproduce, and that file records how. Eight items overlapped this branch: it had fixed or partly fixed items 1, 2, 5, 20 and 25, and items 6, 7 and 8 were open. The merge at `6b977fc` settled each one:

| Item | After the merge |
|---|---|
| 1. Sync status draws over the sidebar | `main`'s safe area bar with a hard scroll edge replaces `f7b3ff9`. |
| 2. Columns overflow narrow windows | `main`'s `0b1477e` replaces `55d09a4`. Restoring the stored column choice still clears the automatic state. |
| 5. Toolbar items merge into one capsule | `main`'s capsules replace the spacing from `dc69a8a`. |
| 6. The Assistant button lands in the overflow menu | `main`'s toolbar tiers, which its review records as keeping search and the assistant in the toolbar down to 720 points. In Attachments, `1d47301` folds the layout and sort controls so search stays there too. |
| 7. Moving between sections | `main`'s switcher shows segments when the toolbar has room and a pop-up menu when it doesn't. It replaces the Phase 3 choice of a pop-up in Calendar only, with the sidebar's Library rows elsewhere. |
| 8. Unlabeled toolbar menus | `main`'s `8d6f9b6` names the profile and mail action menus. |
| 20. Discard sits next to Send | `main`'s layout: Discard Draft before the title, and Send and Archive in its own item. This branch keeps the edited-document dot and the problem alerts. |
| 25. Attachments repeats itself | `main`'s single count and first-pass progress. The layout and sort controls stay in the window toolbar from Phase 7. |
| 3, 9 to 19, 21 to 24, 26 | Arrived with the merge as `main` built them. `e84f73e` took the Library section out of the sidebar, because the section switcher covers Calendar and Attachments. |

## HIG checklist

The `macos-design-guidelines` evaluation checklist, walked against the code, the phase records above and the Debug build in `--ui-audit` mode with synthetic accounts. The installed app was not used, because it holds the user's real account. The menu bar was read through accessibility from the Debug build (153 commands, 75 of them with key equivalents, counting system items such as Services, Writing Tools and Window ▸ Move & Resize).

| Area | Item | Status |
|---|---|---|
| Menu bar | Complete menu bar with standard menus | Met. The bar reads Tern, File, Edit, View, Mailbox, Message, Format, Calendar, Go, Window and Help. Mailbox, Message and Format follow Apple Mail's order. The dump showed Window ▸ Tern and Window ▸ Assistant twice, once as SwiftUI's scene items and once as the app's own buttons, so `3a27dac` put ⌘0 and ⌥⌘A on the scene items and removed the buttons. |
| | Keyboard shortcuts for all actions | Partly. Frequent mail, compose, calendar and navigation commands have key equivalents, as in Apple Mail. Settings toggles, account items, Undo Send, Copy Link, Open in Gmail, Share…, Export as PDF… and the calendar's Refresh, Manage Calendars…, Import Events… and Export Calendar have none. Help ▸ Keyboard Shortcuts is ⌘/, which macOS shows as ⌘' with this Mac's Swiss German layout. |
| | Items enable, disable and retitle with state | Met. Archive and Trash count the selection, Read and Unread and Star and Unstar follow it, and message commands disable with nothing selected. |
| | Context menus on interactive elements | Met: list rows, sidebar mailboxes, reader headers, cards, label chips and links, attachments, recipient tokens, calendar events, library files, and assistant replies, cards and code blocks. |
| | App menu has About, Settings, Hide and Quit | Met. About Tern, Settings… (⌘,), Services, Hide Tern (⌘H), Hide Others (⌥⌘H), Show All and Quit Tern (⌘Q) are present, with Add Account… after Settings. |
| Windows | Resizable with sensible minimums | Met. The main window's minimum is 720 by 480 points, and the sidebar steps aside when three columns don't fit. Compose, conversation, Settings and Assistant windows have minimum sizes. The Keyboard Shortcuts window keeps the size of its content. |
| | Full screen and Split View | Not exercised for the main window. The Assistant window uses the system's full screen. |
| | Multiple windows | Met: conversations, compose, original messages and the assistant open in their own windows. The mailbox stays one window by design, because selection and undo live in one shared model. |
| | Position and size persist | Met. Each scene saves its frame, for example "NSWindow Frame main". |
| | Traffic lights | Met. No window draws custom title bar controls. |
| | Title and edited state | Met. Conversation windows show the subject and participants, and compose windows show the edited dot while closing would save changes Gmail doesn't have. |
| Toolbars | Toolbar with common actions | Met. |
| | User-customizable | Partly. The main window's toolbar is customizable and keeps stable item IDs. The customization palette was not exercised, and the compose toolbar is fixed. |
| | Search field in the toolbar | Met, as an `NSSearchField` item that follows the active section (see the Phase 3 deviations). Since the last merge an idle field folds into a button below 760 points of toolbar room. |
| Sidebars | Sidebar for navigation | Met. |
| | Collapsible | Met: the toolbar button and View ▸ Show Sidebar (⌃⌘S). The state persists, and narrow windows collapse it without saving that as the user's choice. |
| | Source list style | Met. Mail, Calendar and Settings sidebars use the sidebar list style. Favorites reorder by drag, and mailboxes show unread badges. |
| Keyboard | Full keyboard navigation | Partly. Arrows move through lists, the calendar and the library, Return opens or edits, and Esc closes sheets, popovers and the assistant sidebar when its composer is empty. Tab order was not audited. |
| | ⌘Z for destructive actions | Met, with one exception. Triage, labels, spam and importance, calendar edits and Gmail settings changes undo through the window's undo manager with named actions. Delete Forever, Empty Trash and Delete All Spam ask first instead, because Gmail can't restore what they remove. |
| | Space for Quick Look | Met in the message list, reader attachments, compose attachments and the library. |
| | Delete key removes the selection | Met in the message list, which runs the action chosen in Settings, and for editable calendar events. |
| | No keyboard traps | Not audited. |
| Pointer | Hover states | Met through `ternHover` and native list highlighting. |
| | Context menus everywhere | Met (see Menu bar). |
| | Drag and drop | Met: conversations onto mailboxes, labels and the calendar, files out of the reader, compose and the library, events out as `.ics`, and favorites and accounts reorder. Conversations don't drag out as `.eml` (Phase 4). |
| | ⌘-click and ⇧-click selection | Met in lists and the library grid. |
| | Cursor changes | Met: resize cursors on column dividers and calendar grips, and grab pointers while moving events. |
| Notifications | Important events only | Met. New mail notifies per the user's settings and stays quiet while the conversation is on screen. |
| | Suppression option for recurring alerts | Not applicable. Tern shows no recurring alerts. |
| | No modal alerts for routine operations | Met. Confirmations guard permanent deletion, chat clearing and similar actions only, and the two success notices that offered no Undo were removed. |
| System integration | Dock icon | Met. The icon set includes every size up to 1024 pixels, and the Dock menu offers New Message, Check for New Mail, Inbox and Calendar. |
| | Spotlight | Implemented and off by default. Unconfirmed: `mdfind` found no Tern items in the Debug build. |
| | Share | Implemented. Message ▸ Share… was checked through accessibility; the other share points were not run end to end. |
| | App Intents | Implemented: five intents, four of them App Shortcuts. Not checked in the Shortcuts app. |
| Visual design | System fonts at semantic sizes | Met. Text uses system text styles. The three fixed symbol sizes come from tokens, and the two in the sidebar scale with the Sidebar icon size setting. |
| | Dark Mode | Met, checked in light and dark captures. |
| | Accent color | Met. |
| | Translucency follows Reduce Transparency | Not checked with the setting on. Surfaces use system materials, which adapt on their own. |
| | Consistent spacing | Met. Spacing comes from `Tokens.Space`. |
| Popovers | Anchored with an arrow | Met. |
| | Esc dismisses | Met. |
| | Sized to content | Partly checked. Phase 7 sized the attachment filters popover to its content. The others were not measured. |
| Accessibility | Labels on icon-only items | Met in code. Every icon-only button has a label, and `main`'s `8d6f9b6` names the toolbar menus that read as symbol names (review item 8). Not read through accessibility after the merge. |
| | Full Keyboard Access | Not audited. |
| | Reduce Motion | Met through `ternAnimation`. |
| | Reduce Transparency | Not checked (see Visual design). |
| | VoiceOver order | Inspected in the accessibility tree, not walked with speech. |
| | Bold Text | Not applicable. macOS has no Bold Text setting. |
| | Increase Contrast | Met. Status colors are system colors, and custom surfaces read `colorSchemeContrast`. |

## Verification

- Core: 517 tests in 87 suites with `swift test --package-path Packages/Core`, run on the `6b977fc` merge, which brought `main`'s Core changes. No later commit changes `Packages/`.
- Hosted: 349 tests in 58 suites at `e877fdc` and at `7fef621`, 358 on the `6b977fc` merge, and 359 at `1d47301`.
- The Debug build succeeded after every merge and fix. The universal Release build covers arm64 and x86_64, passes `codesign --verify --deep --strict` and reports no app warnings. Its three Core warnings predate this work. It was built from `e877fdc`, before the last two merges with `main`.
- Native checks used the Debug `--ui-audit` app with synthetic accounts: light and dark captures at 720, 960 and 1280 points, sidebar symbols at Small, Medium and Large through a per-process `NSTableViewDefaultSizeMode` override, the menu bar read through accessibility, and Window ▸ Tern reopening a closed main window. After the `6b977fc` merge the audit app opened on another Space, where its windows could not be reached without switching the user's Space, so the merged toolbar was checked in hosted test windows instead: the visible items and rendered captures at 1,280, 960 and 720 points.
- Two full hosted runs were disturbed by other sessions. In one, another session quit the shared test host. The other ran 40 to 50 times slower while other sessions built and tested, and seven suites failed on timed waits. Each rerun on a quiet machine passed.
- Local verification records documented the Release installation and its first launch.

## Known limits

- VoiceOver output was inspected through the Accessibility Inspector, not spoken.
- Live Gmail, Google Calendar and ChatGPT calls were not used for verification; synthetic mail and events stand in.
- Spotlight indexing is unconfirmed: `mdfind` found no Tern items in the Debug build.
- Full screen for the main window, the toolbar customization palette, Tab order, Full Keyboard Access and Reduce Transparency were not exercised.
- The UI that `main`'s review work brought in was checked in hosted test windows, not in the `--ui-audit` app.

## Follow-ups

- `HTMLImporter` in Core collapses the whitespace inside `pre` elements, so a styled code block pasted as HTML loses its indentation.
- Confirm Spotlight indexing with a signed build before relying on it. The setting stays off by default.
- Debug runs log "Application performed a reentrant operation in its NSTableView delegate". The source is not traced.
- In Attachments, which has no assistant button, the assistant's toolbar space still shows after Search.
- Undo Send has no key equivalent.
- The Keyboard Shortcuts window prints the catalog's keys, while the menu bar shows the keys macOS remaps for the active layout. With Swiss German, ⌘/ shows as ⌘'.

## Deferred

- WebKit for SwiftUI's `WebView`: the privacy configuration (nonpersistent store, content blockers, user scripts) stays on `WKWebView`.
- Inline reply in the reader.
- Re-platforming Settings on `NavigationSplitView`.
- Full localization; hardcoded weekday names and formats are fixed, string catalogs are not added.
- A user-customizable shortcut editor; the catalog makes it possible later.
