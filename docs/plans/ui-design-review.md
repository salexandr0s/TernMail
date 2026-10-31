# UI design review

Date: 2026-10-31. The audit build came from `ab7f2c7`, and file references were checked again at `1f1e304`.

This is a list of suggested design changes, not an approved plan. Each item gives what the screen showed, where the code lives, the suggested change, and how sure I am. Items are grouped by area and ranked within each group. The first section collects the defects, which are worth fixing before any restyling.

## Implementation status

Implemented on `feat/ui-design-review` on 2026-10-31. Item 4 did not reproduce in an active window and has no change. Every other item shipped. "Differs" in the table means the change departs from the suggestion, and the next section says how.

| Item | Status | Commits |
|---|---|---|
| 1. Sync status draws over the sidebar | Done, differs | `3f1538e` |
| 2. Columns overflow narrow windows | Done, differs | `0b1477e` |
| 3. Tab skips Subject after the From account switches | Done, differs | `09b8af7` |
| 4. A message body clipped after the reader narrowed | Not reproduced | |
| 5. Toolbar items merge into one capsule | Done | `7103144` |
| 6. The Assistant button lands in the overflow menu | Done, differs | `1346d8d` |
| 7. Moving between sections | Done, differs | `1346d8d`, `e84f73e` |
| 8. Unlabeled toolbar menus | Done, differs | `8d6f9b6` |
| 9. Inbox sits below Calendar and Attachments | Done | `e84f73e` |
| 10. Empty section headers | Done | `e84f73e` |
| 11. Chevrons and account names in the sidebar | Done | `784d095` |
| 12. Account badges draw too much attention | Done | `e5718ef`, `fbf3512` |
| 13. Search results lack scope and highlighting | Done, differs | `8a6f75f`, `85333df`, `9ff57e3`, `326c561`, `32d39b2`, `b4cd75f`, `49fdd0f`, `93c0853`, `2454b13`, `38a946f` |
| 14. The empty reader text gives odd advice | Done | `709e632` |
| 15. Every message stays expanded | Done | `5483c97` |
| 16. AI summary and Connect prompts before setup | Done, differs | `84da4ae`, `4486d1d`, `ea8b5ab` |
| 17. Per-message controls stack up | Done, differs | `f87678c`, `8e1b631`, `1c6756c`, `9566195` |
| 18. The Inbox chip's X archives the thread | Done | `137fe46` |
| 19. Header fields look like a web form | Done | `b164338` |
| 20. Discard sits next to Send | Done, differs | `68d6133` |
| 21. Recipient tokens and sender changes | Done, differs | `3067d8f`, `bd42025`, `09b8af7`, `cce5621`, `873314a` |
| 22. Labels repeat their headers | Done | `db4e796` |
| 23. 21 panes, with two for signatures | Done | `cc4ef36`, `03f6da0`, `1cbd46f` |
| 24. Smaller Settings fixes | Done | `76ac275`, `1477a0c`, `5ce756d`, `08c36f2`, `fd5c9df` |
| 25. Attachments repeats itself | Done | `211f1da`, `39c279a`, `45f20f5` |
| 26. Calendar asks four times to connect | Done, differs | `21ed874`, `49fc37d` |

### How the changes differ from the suggestions

- Item 1: the footer sits in a safe-area bar with a hard scroll edge effect, in place of `.background(.bar)` and a `Divider()`. The edge effect separates it from the rows that scroll under it.
- Item 2: below the three-column minimum the sidebar hides on its own. It returns once the window fits the sidebar beside the 720-point window minimum (949 points with the default sidebar), because AppKit widens the window when a sidebar opens with less room. The sidebar button clears the automatic state.
- Item 3: when the sender switches by itself, the cursor goes back to where it was instead of moving to Subject.
- Item 6: the tiers follow the room the toolbar has after the sidebar, or after the window controls while the sidebar is hidden, instead of the window width. Below 1080 points of room the section switcher becomes a pop-up menu and the profile picker drops its name. Below 1020 the mail actions fold into menus. Below 760 an idle search field folds into a button that opens it. With the sidebar shown, search folds in windows narrower than about 988 points, where the review suggested about 900. Search and the assistant stay in the toolbar down to the 720-point minimum.
- Item 7: the switcher shows segments when the toolbar has room and a pop-up menu when it doesn't. With the sidebar shown, the segments appear from a window about 1308 points wide.
- Item 8: done here rather than in Phase 5 of `docs/plans/swiftui-improvements.md`. The profile picker shows the profile name only in the widest tier and stays hidden when there are no profiles.
- Item 13: the window title reads "Search Results" and the subtitle gives the count, as in "12 results". AppKit shows window titles in the Window menu and Mission Control and can keep them in saved window state, and search terms are meant to stay unstored. The scope bar sits under the list header, not under the search field. It offers All Mail or the selected mailbox, an account menu when search covers several accounts, and Save. The scope wraps the whole query, as in `in:inbox (trail OR lake)`. Gmail's search syntax has no escapes, so a label whose name contains a double quote gets no scope and no search suggestion.
- Item 16: after setup, the summary card also stays hidden in threads from accounts without AI access or outside the assistant's scope, instead of showing a prompt there.
- Item 17: blocked images get one bar above each open message's body, not a line per thread. Reading settings describe Load Images as acting on one message, and the thread-wide button also loaded images in messages opened later. The bar holds Load Images and Always Load from Sender, and it shows only when Load Images would load something. The tracker count is a hand icon beside the message time, with a popover saying trackers stay blocked after Load Images.
- Item 20: Discard Draft moved to the leading side of the toolbar, before the title. Send and Archive sits in its own arrow item after Send and shows only for replies and forwards. A toolbar menu with a primary action renders without the prominent style, so Send stays a separate prominent button.
- Item 21: a new compose window steps away from the open ones through a small view that moves it as it opens, not `defaultWindowPlacement`. Windows that open as tabs or in full screen don't step. The sender note's Undo button hides when the previous account has signed out.
- Item 26: the Calendar sidebar keeps its per-account Cancel Sign-In and Retry buttons.

### Verification

- `swift test --package-path Packages/Core`: 517 tests in 87 suites passed.
- `xcodebuild test` with `-only-testing:TernTests`: 343 tests in 55 suites passed. `e29b2ff` gave the sidebar layout tests their own toolbar identifier. AppKit mirrors item changes across toolbars that share an identifier, and the test host's main window already used the workspace one, which crashed the run.
- Screenshots of the `--ui-audit` build with synthetic data: Mail in light at 1280, 960 and 720 points and in dark at 1280 and 720; Calendar in light at 1280 and in dark at 960 and 720; Attachments in light at 1280 and 720 and in dark at 960.

### Not verified

- The search results screen after the last list fixes (title, subtitle, status text and scope bar). Tests cover it, but no screenshot does.
- Compose: the cascade's timing, and the tab and full screen cases.
- Calendar's Cancel Sign-In and Retry buttons.
- Areas the second code review did not cover: the VoiceOver labels on Send and More Send Options, the From row highlight timing, the cursor restore, avatars in recipient tokens, the compose header rows, the template menu, `ConversationWindow` re-creation, the privacy line's counts, the welcome setup card, and the narrow header layout.
- As in the original review, there was no VoiceOver pass and no live Gmail data.

### Found during the checks

These also happen on `main`.

- After a window shrinks from 1280 to 960 points, the Calendar sidebar grows to its 320-point maximum and the week grid cuts off Sunday.
- The "Calendar" title crosses the sidebar's edge.
- Audit builds sometimes hold the CPU near 100%: AppKit's animation timer redraws the window and SwiftUI lays out the hosting view on every frame. It showed up with audit windows on another Space.
- Debug builds only: under plain `--ui-audit`, attachment indexing is off but the index progress still waits on every syncing account, so its spinner never stops. `--ui-audit-attachments` turns indexing on.

## Method

The app ran in the Debug `--ui-audit` mode, with synthetic mail for two accounts (`audit@example.invalid` and `second@example.invalid`). Flags used: `--ui-audit-list`, `--ui-audit-calendar`, `--ui-audit-dark` and `--ui-audit-light`. Windows were captured at 720, 960 and 1280 points wide, in light and dark appearance.

Screens covered: inbox, reader, compose (empty, recipient suggestions, filled, formatting bar), Settings (General, Message List, Connections), the assistant panel, search results, Attachments, and Calendar both unconnected and with sample events. For each finding I read the view code behind it.

Not covered: live Gmail data (long threads, heavy HTML newsletters, large mailboxes), a VoiceOver pass, Increase Contrast and Reduce Transparency, context menus, notices and toasts, the Outbox, Drafts and Snoozed lists, and keyboard navigation beyond the compose Tab test.

Some current placements may have been chosen on purpose to match the reference captures in `docs/research/`. Where a suggestion moves such a control, treat it as a question for that decision, not as a defect.

## Summary

The ten changes I would make first, in order:

1. Give the sidebar sync footer a background so it stops drawing over the last rows.
2. Stop the three columns from overflowing a window narrower than 816 points.
3. Fix Tab focus in compose after the From account switches by itself.
4. Separate the toolbar into groups so nine actions stop sharing one glass capsule.
5. Put Inbox and the mailboxes at the top of the sidebar, and hide empty section headers.
6. Collapse read messages in the reader and shorten the message header.
7. Hide the AI summary card and the duplicate Connect prompts until the assistant is set up.
8. Move Discard Draft away from Send in compose, and turn Send and Archive into an option on Send.
9. Use one section switcher (Mail, Calendar, Attachments) in the same place in every section.
10. Merge the two signature panes in Settings and remove labels that repeat their headers.

## Defects

### 1. Sync status draws over the sidebar

Seen: in every capture, light and dark, "Updated 30 seconds ago" sits on top of the last visible sidebar row: "Projects" and the second account's header at 1280 points, "Saved Searches" at 720. The footer has no background, so neither text can be read.

Where: `App/Views/SidebarView.swift:83` places `SyncStatusView` in `.safeAreaInset(edge: .bottom)`. The view at line 417 draws text only. List rows scroll under a safe area inset by design, so the inset needs its own surface.

Change: give the inset `.background(.bar)` and a top `Divider()`. The failed state, with its Try Again button, gets the same treatment. A quieter option is to show status only while syncing or after a failure, and put the last-updated time in the button's help text.

Confidence: high.

### 2. Columns overflow narrow windows

Seen: at the 720-point minimum width the split view is wider than the window. The sidebar loses its left edge (the Favorites header reads "tes", the Inbox icon is cut), and the reader loses its right edge (the subject is cut mid-word, and the message time and Reply button fall off).

Where: the column minimums add up to 816 points. Sidebar 180 plus the 8-point gutter (`App/Views/MainView.swift:151`), list 300 plus 8 (`MainView.swift:174`), reader 320 (`MainView.swift:182`, `Tokens.Assistant.readerMinWidth`, which equals `Layout.emptyStateWidth`). `Tokens.Layout.windowMinWidth` is 720 (`App/Design/Tokens.swift:130`).

Change: collapse the sidebar on its own when the window is narrower than the three minimums, and restore it when the window grows. The sidebar toggle already exists, so this reuses its state. The other fix, raising the window minimum to about 820 points, also works but removes a useful size on a 13-inch display shared with another app.

Confidence: high.

### 3. Tab skips Subject after the From account switches

Seen: in a new message with From set to the first account, typing "sa" and accepting the suggestion "Sam" (a contact of the second account) switched From to "Second Audit". The next Tab put the cursor in the body, so the subject text was typed into the body. The same steps with "ri" and River, a contact of the current account, moved focus to Subject as expected. Reproduced twice.

Where: `App/Compose/RecipientAvatarController.swift:72-79` accepts the suggestion on Return or Tab. The From change goes through `ComposeModel.selectSender` (`App/Compose/ComposeModel.swift:248`). The From row redraws while the Tab is still being handled, which likely resets the key view loop.

Change: after accepting a suggestion that changes the sender, set focus to Subject explicitly once the From row has updated, for example by setting the compose focus state on the next run loop turn. Add a regression test only if the compose focus code already has a test seam.

Confidence: high on the symptom, medium on the cause.

### 4. A message body clipped after the reader narrowed

Seen: with the assistant panel open at 1280 points, the second message's last line was cut in half ("let us know which", then a clipped line).

Where: `App/Views/ThreadView.swift:807` sizes the web view from a height that `App/Views/MessageWebView.swift` reports through a `ResizeObserver` (line 122) and a width-change hook (`MessageWebView.swift:60`, `setFrameSize` at line 323). The mechanism looks right.

Change: reproduce it first with the window active. The capture was taken while the window was not key, and WebKit may delay resize callbacks in background windows. If it repeats in an active window, measure again when the column animation ends.

Confidence: low. Seen once, in a background window.

## Window and toolbar

### 5. Toolbar items merge into one capsule

Seen: at 1280 points, Archive, Trash, Read, Move, Labels, Snooze, Reply, Reply All and Forward share one glass capsule. The Assistant button joins the search field's capsule, so it reads as part of search. Calendar shows the same thing: New Event (+) joins the search field.

Where: `App/Views/MailToolbar.swift:20-73` declares the items back to back with no spacer. On macOS 26, adjacent toolbar items share a glass group unless something separates them.

Change: add `ToolbarSpacer` between groups: [Archive, Trash] [Read, Move, Labels, Snooze] [Reply, Reply All, Forward] [More] [Search] [Assistant]. In Calendar, separate New Event from search the same way.

Confidence: high.

### 6. The Assistant button lands in the overflow menu at 960 points

Seen: at 960 points the Assistant button moves into the ">>" overflow. At 720 the search field moves there too, so the window has no visible search. While resizing, the triage capsule briefly drew clipped.

Where: `App/Views/MainView.swift` toolbar, with the compact switch at `Tokens.Layout.compactToolbarWidth` (1120).

Change: keep search and the assistant visible at every width. The compact layout could also fold Read, Move, Labels and Snooze into the More menu, which leaves room for both. Search could shrink to an icon that expands on click below about 900 points.

Confidence: medium. The best split depends on how often each action is used.

### 7. Moving between sections works differently in each direction

Seen: Mail opens Calendar from a sidebar row. Calendar returns to Mail through a small icon-only popup at the top left labeled "Section", which also lists Attachments. Mail has no such popup, so the way back is not where the way in was.

Where: `App/Views/SidebarView.swift:13-23` (the Library section) and the Calendar toolbar's section popup.

Change: use one control in the same toolbar spot in every section. A segmented control (Mail, Calendar, Attachments) fits the HIG pattern for switching views. Remove the Library section from the mail sidebar once the switcher exists (see item 9).

Confidence: high on the inconsistency. The control type is a design choice.

### 8. Unlabeled toolbar menus

Seen: VoiceOver names the profile picker "chevron.popup", and the More menu and the compose template menu "chevron.pulldown". The profile picker shows a tray icon with up and down chevrons, which does not say what it switches. The New Message button disappears from the toolbar in Attachments.

Where: `App/Accounts/ProfilePicker.swift:6` (the Picker title "Profile" is not exposed in the toolbar), `App/Views/TriageControls.swift`, `App/Compose/ComposeView.swift:454-460`.

Change: add `.accessibilityLabel` and `.help` to each menu. Phase 5 of `docs/plans/swiftui-improvements.md` already covers icon-only controls, so fold these three sites into it. For the profile picker, show the active profile's name next to the icon, or move profiles into the section switcher's menu. Keep New Message in the Attachments toolbar.

Confidence: high.

## Sidebar

### 9. Inbox sits below Calendar and Attachments

Seen: the sidebar opens with Library (Calendar, Attachments), then Favorites (Inbox and the rest), Saved Searches, Mailboxes, and one section per account. In a mail client, Inbox is the first thing people look for.

Where: `App/Views/SidebarView.swift:13-25`.

Change: start with Favorites. Move Calendar and Attachments to the section switcher from item 7, or below the account sections.

Confidence: medium. This is a structural preference. Apple Mail opens its sidebar with Favorites and Inbox.

### 10. Empty section headers

Seen: with two accounts, the "Mailboxes" header shows with no rows under it, because every combined mailbox is already a favorite. "Saved Searches" shows with no saved searches, only a + button.

Where: `App/Views/SidebarView.swift:29` (the combined Mailboxes section) and `SavedSearchRows`.

Change: skip a section when it has no rows. Offer New Saved Search from the search results header or the File menu instead of a permanent empty header.

Confidence: high.

### 11. Chevrons and account names in the sidebar

Seen:

- Every favorite has a disclosure chevron, including the ones that are collapsed, so the left edge shows a column of chevrons.
- Expanded rows list each account by the part of its address before the @, so "audit" and "second" sit under All Mail and again under Spam.
- At 1280 points with the assistant open, the second account header is cut in the middle ("second@e...ple.invalid").
- The Favorites header control is an ellipsis circle followed by a chevron, which reads as two controls.

Where: `App/Views/SidebarView.swift` (`CombinedMailboxRows`, `AccountHeader`) and `FavoritesView`.

Change: show the chevron only on hover or on rows that are expanded, as Finder does. Name account rows with the account's display name or a short label the user sets, and keep the colored dot. Truncate addresses at the end, so the start of the address stays visible. Make the Favorites control a single "Edit Favorites" button or a context menu item.

Confidence: medium.

## Message list

### 12. Account badges draw too much attention

Seen: every row in the combined inbox carries a colored outlined badge ("SE", "AU"). In dark mode the red and blue outlines are the brightest marks in the list, ahead of unread dots and stars. The colored rings around contact avatars add more color.

Where: `App/Views/MessageListRow.swift` (the badge is `Text(accountMark)` with a colored stroke). The current form comes from `docs/plans/conversation-list-density.md`.

Change: keep the initials but drop the outline, and show the account color as a small dot or a 2-point leading bar. Show badges only in combined mailboxes, which may already be the case. Drop the avatar rings, or use a neutral ring.

Confidence: medium. The density plan chose badges on purpose. This changes only how loud they are.

### 13. Search results lack scope and highlighting

Seen: the list title reads "Search Results" with no count and no scope. The sidebar keeps Inbox selected, so it looks as if the search covers only Inbox. Matching terms are not highlighted in rows. The "Search Gmail" fallback button works well.

Change: title the list with the query and count ("12 results for trail"). Show scope as tokens or a small segmented control under the search field (All Mail, the current mailbox, one account). Highlight matches in the subject and preview. Clear the sidebar selection while a search is active.

Confidence: medium on the layout, high on the scope confusion.

### 14. The empty reader text gives odd advice

Seen: with nothing selected, the reader says "Select a conversation" and then "Start a new message with ⌘N."

Where: `App/Views/MainView.swift:446`.

Change: show the selected mailbox's name and unread count, or the title alone. The ⌘N hint is unrelated to selecting a conversation.

Confidence: medium.

## Reader

### 15. Every message stays expanded

Seen: in a two-message thread both messages are open. Each header takes three to four lines at narrower widths: name with two chevrons, To line, time on its own line, then star, Reply and More on another line. Long threads will turn into a long scroll of repeated headers.

Where: `App/Views/ThreadView.swift`, message header and `expanded` state.

Change: open the newest message and any unread ones, and collapse the others to a single line (sender, first line of the body, time). Put the time and the action buttons on the name line, and drop the second chevron. One chevron is enough for both the sender menu and collapsing.

Confidence: high on the density, medium on the exact header.

### 16. AI summary and Connect prompts before setup

Seen: every thread opens with an "AI summary" card that only says "Connect ChatGPT for a summary." With the assistant panel open, a second Connect prompt shows in the panel at the same time. The panel's starter cards are dimmed, so they look broken rather than unavailable. The empty composer shows a blue focus ring while it is disabled.

Where: `App/Views/ThreadView.swift:133` shows `ThreadSummaryView` whenever no message is selected. `App/Assistant/ThreadSummaryView.swift:50-53` handles the unavailable case by showing the reason and an action.

Change: hide the summary card while the assistant is not set up, and keep a single setup prompt in the assistant panel. Hide the starter cards until setup is done, or show them at full strength with a note that they need setup. Remove the focus ring from the disabled composer.

Confidence: high.

### 17. Per-message controls stack up

Seen: in dark mode, each message has its own "Show with Light Background" line above the body. Messages with blocked images add a privacy banner, a tracker count and Block Images for Sender, each in its own row. A thread of five newsletters repeats all of them five times.

Where: `App/Views/ThreadView.swift:770-799`.

Change: move Show with Light Background to the message's More menu and the View menu, and remember the choice per sender. Combine the remote content notice and the tracker count into one line per thread, with Load Images acting on the whole thread.

Confidence: medium.

### 18. The Inbox chip's X archives the thread

Seen: the label chip "Inbox" next to the subject has an X. For Inbox, removing the label means Archive, but the X looks like closing a tag.

Where: `App/Views/ThreadView.swift:523` (`LabelChip`).

Change: hide the X on the Inbox chip and leave Archive to the toolbar, or show an archive icon with the help text "Archive".

Confidence: medium.

## Compose

### 19. Header fields look like a web form

Seen: To, Subject and From are separate rounded boxes with borders. `docs/plans/compose-polish.md` describes left-aligned labels with dividers between rows, so the current window differs from that plan.

Where: `App/Compose/ComposeView.swift`, header rows.

Change: use borderless rows with hairline dividers, as the compose plan describes.

Confidence: high.

### 20. Discard sits next to Send

Seen: the toolbar order is Formatting, Insert Template, then Attach Files and Discard Draft in one capsule, then Send, then Send and Archive. The trash button is one gap away from Send. Send and Archive uses a bare archive box icon, so it reads as Archive.

Where: `App/Compose/ComposeView.swift:435-510`.

Change: keep Send at the trailing edge, as the compose plan decided, but move Discard Draft to the leading side or into a menu, with a spacer between it and Attach. Make Send and Archive a second choice on Send: a menu on the Send button, or an Option-click alternate. If it stays a separate button, give it a combined icon and the help text "Send and Archive".

Confidence: high on the Discard placement, medium on the menu.

### 21. Recipient tokens and sender changes

Seen:

- The avatar on a recipient token overlaps the token's left edge, and the token has wide padding around the name.
- Picking Sam switched From to Second Audit without any sign that it happened. Afterwards "SA" stood for both Sam and Second Audit.
- Two new compose windows opened at the same position, one on top of the other.

Where: `App/Compose/RecipientAvatarController.swift`, `App/Compose/ComposeModel.swift:248`, and the "New Message" window group at `App/TernApp.swift:47-52`.

Change: inset the avatar inside the token and trim the padding. When the sender changes on its own, highlight the From row briefly and show "Sending from Second Audit because Sam is a contact there", with an Undo button. Offset each new compose window from the last one, for example with `defaultWindowPlacement` or a window position based on how many compose windows are open.

Confidence: high on the overlap and stacking, medium on the notice wording.

## Settings

### 22. Labels repeat their headers

Seen: the General pane has a section "Default email app" containing a row "Default mail app". The sidebar group "General" holds a pane also called "General". Each pane opens with a subtitle that lists its own section headers ("Default email app, sending and keyboard shortcuts.").

Where: `App/Views/SettingsView.swift` and the General pane.

Change: drop the row titles and subtitles that restate a header, use "mail" or "email" consistently, and rename either the group or the pane.

Confidence: high.

### 23. 21 panes, with two for signatures

Seen: the sidebar lists 21 panes, including "Signatures" (local) and "Gmail Signatures". The pane under Accounts is called "Preferences", which does not say what it holds.

Where: `App/Settings/SettingsNavigation.swift:4-44`.

Change: merge the signature panes into one, with a source control for local or Gmail signatures. Rename "Preferences" after its contents (for example "Account Settings").

Confidence: medium. Merging signatures changes how the two stores are explained.

### 24. Smaller Settings fixes

Seen:

- The swipe action popups in Message List are centered in their columns, so their chevrons do not line up.
- "After archiving or moving to Trash: Below" does not say what is below. "Select the conversation below" would.
- In Connections, Permanent Deletion sits among the ordinary toggles.

Change: left-align the popups on a shared leading edge. Spell out the selection rule. Move Permanent Deletion into its own section with a short warning.

Confidence: high.

## Attachments and Calendar

### 25. Attachments repeats itself

Seen: the toolbar search field and a search field in the page are both visible. "0 attachments" shows in the header and again in the status bar. The empty state "Your files, together" shows while the footer says "Preparing attachment index…". The page header repeats the window title.

Change: keep one search field (the toolbar one). Show the count once. While the index is being built, show progress in place of the empty state. Drop the in-page title.

Confidence: high.

### 26. Calendar asks four times to connect

Seen: with two accounts and no calendar access, the sidebar and the main area each show a Connect Google Calendar button per account, four in all.

Change: show one prompt in the main area that lists both accounts, and leave the sidebar with the month grid only.

Confidence: high. With sample data in dark mode the calendar reads well: the today column is tinted, events have readable contrast, and the time zone in the status bar is useful.

## Suggested order

1. Defects 1 to 3, each a small change in one file or two.
2. Toolbar grouping (5) and the accessibility labels (8), folded into Phase 5 of `docs/plans/swiftui-improvements.md`.
3. Sidebar order, empty headers and the section switcher (7, 9, 10). These change navigation, so they need a decision before work starts.
4. Reader density and the assistant prompts (15 to 17).
5. Compose and Settings (19 to 24), then Attachments and Calendar (25, 26).

Item 4 needs a reproduction in an active window before anyone works on it.
