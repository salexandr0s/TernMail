# TernMail design tokens

This inventory records the app's current design as a baseline for refinement. It covers shared tokens, UI components, local visual values, native controls, and app-authored email/print styles. The first pass preserves the app's visual values and gives recurring text and action choices shared names.

Open [the searchable catalog](catalog.html) in a browser. It works offline and includes every entry from [the JSON inventory](design-token-inventory.json), with source locations and token uses. The catalog's colors illustrate the reference page; they are not TernMail's native colors.

## Source of truth

| Source | Responsibility |
| --- | --- |
| [Tokens.swift](../../App/Design/Tokens.swift) | Shared scales, semantic surfaces/status, component dimensions, opacity, motion, and presentation policies |
| [TokenRoles.swift](../../App/Design/TokenRoles.swift) | Shared text hierarchy, accent, and typography roles |
| [OnboardingComponents.swift](../../App/Onboarding/OnboardingComponents.swift) | `Tokens.Onboarding` window and page metrics |
| [Components.swift](../../App/Design/Components.swift) | Badge, avatar, empty-state, surface, outline, hover, and animation recipes |
| [PopupComponents.swift](../../App/Design/PopupComponents.swift) | Shared sheet/popover header and footer |
| [TernTransition.swift](../../App/Design/TernTransition.swift) | Disclosure, fade, and edge-panel presentation |

Swift declarations are authoritative. The JSON and HTML catalog are generated observations, not a second editable token source. Expressions and aliases remain intact; macOS resolves colors and text styles at runtime. This is a repository-specific inventory format, not a DTCG interchange file.

The spacing, radius, and motion scales originated in the workspace design contract. TernMail uses native macOS colors and type instead of the web palette and font sizes in that contract. This repository contains the definitions needed to build the app.

## Component inventory

The catalog lists individual source definitions and their directly observed token dependencies. The following families describe how those definitions fit together. Private helper views are included in the generated list; the list is not a claim that each helper is a reusable public component.

| Family | Components in use | Primary source / contract |
| --- | --- | --- |
| Shared primitives | `TernBadge`, `AvatarImage`, `TernAvatar`, `TernEmptyState`, `FlowLayout`; `ternSurface`, `ternOutline`, `ternHover`, `ternAnimation`, `ternTransition` | [Design](../../App/Design/Components.swift); shared scales, native text, contrast and motion |
| Identity and imagery | `AddressAvatar`, `ContactAvatar`, `DomainLogoAvatar`, `CalendarDateTile` | [AddressAvatar](../../App/Design/AddressAvatar.swift); avatar size roles, stable initials, provider assets, fixed date face |
| Workspace | `MainView`, `MailColumnsContent`, `WorkspaceView`, split divider/handle, workspace toolbars and search | [MailColumnsContent](../../App/Views/MailColumnsContent.swift); `Layout`, `Assistant`, `Calendar`; native sidebar material |
| Mail navigation | `SidebarView`, `MailboxRow`, `AccountHeader`, `LabelRow`, favorites, sidebar footer, account/profile pickers | [SidebarView](../../App/Views/SidebarView.swift); native list selection, system sidebar size, account/label identity colors |
| Message list | `ThreadListView`, `MessageListRow`, `MessageListVisualRow`, `MailLabelBadge`, `MessageListHeader`, search suggestions | [MessageListRow](../../App/Views/MessageListRow.swift); `MessageList`, reader-scaled native typography, list avatar |
| Reader | `ThreadView`, `ThreadHeading`, `MessageView`, `MessageHeader`, message details/actions, label chips, `ReaderFindBar`, `MessageWebView` | [ThreadView](../../App/Views/ThreadView.swift); `ConversationHeader`, readable width, primary cards, WebKit body |
| Mail actions and feedback | `NoticeView`, `MailNoticeOverlay`, outbox, destructive review, snooze, label/favorite/search editors | [NoticeView](../../App/Views/NoticeView.swift); `Toast`, `Popover`, `Sheet`, status colors and native dialogs |
| Composer | `ComposeView`, `FormatBar`, `RichTextEditor`, `ComposeTextView`, `ComposePromptField`, signature/quote/link editors | [ComposeView](../../App/Compose/ComposeView.swift); `Compose`, `Layout`, native text system |
| Recipients | `RecipientField`, `RecipientTokenField`, `RecipientSuggestionsPanel`, `RecipientSuggestionCell`, `SenderAccountLabel` | [RecipientSuggestionsPanel](../../App/Compose/RecipientSuggestionsPanel.swift); AppKit token/selection rendering, native fonts, compact avatar |
| Attachments | `AttachmentChip`, `AttachmentStrip`, received attachments, library rows/cards/collection, filters and selection actions | [AttachmentLibraryRows](../../App/Attachments/AttachmentLibraryRows.swift); card/chip geometry, file-type colors, native file icons |
| Calendar navigation | `CalendarSidebar`, `CalendarMiniMonth`, weekday header, toolbar, search results, schedule rows | [CalendarMiniMonth](../../App/Calendar/CalendarMiniMonth.swift); `Calendar`, date cells, provider colors |
| Calendar canvas | `CalendarTimeGrid`, `CalendarMonthGrid`, `CalendarEventChip`, `CalendarTimelineEvent`, grid views | [CalendarTimeGrid](../../App/Calendar/CalendarTimeGrid.swift); event/today/selected tints, local grid geometry |
| Calendar editors | Event editor, sheet heading, recurrence and time-zone controls, inline errors, activity/recovery views | [CalendarEventEditor](../../App/Calendar/CalendarEventEditor.swift); calendar sheet sizes and native controls |
| Tasks | `GoogleTasksSidebar`, `GoogleTaskRow`, `GoogleTaskEditor`, conflict review, email task actions | [GoogleTaskRow](../../App/Tasks/GoogleTaskRow.swift); completion accent, overdue status, date tiles and action targets |
| Assistant conversation | `AssistantView`, `AssistantConversationView`, `AssistantMessageView`, composer, launcher, welcome and scope notices | [AssistantView](../../App/Assistant/AssistantView.swift); `Assistant` panel, bubble, content and composer roles |
| Assistant content | Markdown, code, table, diagram, email/task/event cards, result footer, summaries and review sheets | [AssistantResultCards](../../App/Assistant/AssistantResultCards.swift); `AssistantFormatting`, `ConversationHeader`, shared date tile |
| Analytics | Metrics, activity chart, history, message lists, sender popover, read-receipt badge | [AnalyticsPresentation](../../App/Analytics/AnalyticsPresentation.swift); `Analytics`, teal received/indigo sent, contrast-aware panels |
| Settings | `SettingsPage`, editor sheet, footer, control/toggle rows, notes/errors; account, reading, compose, assistant and integration panes | [SettingsComponents](../../App/Settings/SettingsComponents.swift); `Settings`, grouped forms, system field and control styles |
| Accounts and profiles | Profile picker/editor/schedule, preferences, notification controls, `SwatchPicker`, reconnection banner | [SwatchPicker](../../App/Accounts/SwatchPicker.swift); stable account palette, selected checkmark, native controls |
| Onboarding | Window, Google/ChatGPT/preferences steps, feature/note/error components | [OnboardingComponents](../../App/Onboarding/OnboardingComponents.swift); `Onboarding`, shared spacing and semantic status |
| Mail organization | Introduction, loading, category/example rows, review and delivery | [MailOrganizationView](../../App/Organization/MailOrganizationView.swift); shared surfaces, status, spacing, native actions |
| Newsletters | Unsubscribe window/list/row, checkbox, icon actions and confirmation dialogs | [UnsubscribeRow](../../App/Newsletters/UnsubscribeRow.swift); custom selection/hover, status, account identity and native actions |
| Brand and assets | `ChatGPTBrand`, `ChatGPTSignInButton`, app icon, contact/domain images, file icons | [ChatGPTBrand](../../App/Assistant/ChatGPTBrand.swift); approved artwork and monochrome sign-in treatment |
| Message HTML and print | `MessageDocument`, dark-mode adaptation, plain-text wrapper, print document; outgoing attributed text | [MessageDocument](../../Packages/Core/Sources/MessageContent/MessageDocument.swift); separate content/print contracts |

## Token families

Every declaration, exact expression, visibility, and observed use is in the catalog's Tokens tab. This table gives each namespace its intended role.

| Namespace | Current values / meaning |
| --- | --- |
| `Space` | 2, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48, 64 native points; existing `s0_5` through `s16` names stay stable |
| `Radius` | Small 6, medium 10, large 14 points; circles and capsules use native shapes |
| `Border` | Hairline 1 point, focus 2 points; a point is not necessarily one physical pixel |
| `Surface` | Canvas = under-page background; primary = control background; muted = window background; border = separator |
| `Text` | Primary/secondary hierarchical foreground styles; label ink for badge/avatar text that must remain independent of surrounding selection |
| `Action` | Accent follows `Color.accentColor` |
| `Typography` | Native fonts for section titles, supporting text, metadata, fine print, control symbols, badges, avatars and empty states |
| `Status` | Error red, warning orange, success green, star yellow, important orange; roles are distinct even where values match |
| `Opacity` | Hover .06, pressed .10, tint .14, disabled .5, wash .08, outline .5 |
| `Control` | Icon 16, icon button/avatar 32, large avatar 40, list avatar 20; sidebar icon scale follows system row size |
| `Motion` | Fast .12 s, base .16 s, slow .22 s; standard curve `(0.2, 0.8, 0.2, 1)` |
| `Shadow` | Medium shadow: black at .10, SwiftUI radius 10, vertical offset 8 points |
| `Layout` | Window/column/readable widths, minimum sizes, toolbar folding thresholds, search/compose geometry and shared editor dimensions |
| `MessageList` | Unread bold/read regular; appearance-dependent read/unread background policy |
| `ConversationHeader` | Primary surface at .45, border at .6, 32-point date tile and 12-point status badge for generated reading aids |
| `Assistant` | Sidebar min/default/max 320/380/480; content 720; bubble/composer surfaces, insets and radii |
| `AssistantFormatting` | Native reading/code fonts, block/section/list rhythm, result/code/table preview limits and diagram preview size |
| `Compose` | 20-point gutter, assistant content width, 600-point labeled-toolbar threshold |
| `Calendar` | Sidebar/editor/activity dimensions; event .12, all-day .18, selected .24, today .04 tints |
| `CalendarDate` | Fixed white paper, black ink, red month darkened by .20; 25-point task tile |
| `Settings` | Window/sidebar/content/editor geometry, group tint .045, row heights and .75-second live-apply delay |
| `Analytics` | Window/popover/chart geometry, bar width ratio .7, metric minimum scale .6, received teal/sent indigo |
| `Popover` | 320-point width and list-height cap |
| `Sheet` | 420-point small width |
| `Toast` | 360-point width; information 3.5 s, error 6 s |
| `Onboarding` | 1000 × 600 window, 224 sidebar, 560 content, 860 compact threshold, 96-point hero icon |

Preview counts, live-apply delays, and toast durations are presentation/interaction policy values already housed in `Tokens`. Their presence does not make database limits, network timeouts, or calendar snapping intervals design tokens.

### Typography and color ownership

Use native SwiftUI text styles rather than assigning fixed pixel sizes. `Tokens.Typography` names common roles; specialized assistant styles remain in `AssistantFormatting`. Direct `.body`, `.caption`, and `.headline` uses elsewhere are valid native choices and appear in the inventory for later role alignment.

`Tokens.Text.primary` and `.secondary` are `HierarchicalShapeStyle` values, not `Color` values. They preserve the surrounding foreground and selected-row context. Use `Tokens.Text.label` only where the component deliberately needs independent label ink. AppKit recipient selection needs its active/inactive selected text colors; do not replace those with a generic primary color.

| Owner | Existing source | Refinement rule |
| --- | --- | --- |
| macOS semantic appearance | SwiftUI foreground hierarchy; AppKit label, text, separator, control/window background and selected text colors | Retain dynamic resolution, accent and active/inactive selection behavior |
| Application status | `Tokens.Status` | Choose by meaning; a PDF's red icon does not mean error |
| File type | `AttachmentPresentation.tint` | Candidate for a named file-type family; PDF red, image purple, spreadsheet green, presentation/archive orange, audio pink, movie/text blue |
| Account identity | `AccountAppearance.palette` | Preserve stored palette-index order: blue, pink, orange, green, purple, teal, indigo, brown |
| Gmail label | `LabelAppearance` and Gmail foreground/background pairs | Preserve user/provider choices and opaque selected-row contrast |
| Calendar provider | `CalendarColor`, calendar/event records; blue `#4285f4` fallback | Preserve provider values; evaluate appearance transforms separately |
| Fixed illustration | `CalendarDate` | Keep paper/ink/month together when checking contrast |
| External brand | ChatGPT logo and sign-in button | Preserve approved artwork and monochrome treatment |
| Message author/user | HTML body colors, images, outgoing fonts and formatting | Keep content styling separate from application chrome |

## State and accessibility recipes

| State | Current implementation | Refinement requirement |
| --- | --- | --- |
| Default surface | `ternSurface` with primary fill and `ternOutline`; grouped forms tint in dark mode | Prefer existing recipe over copied fill/border expressions |
| Hover | `ternHover`: primary at `.06`, small radius by default, fast motion | Feedback must not replace keyboard focus or be the only route to an action |
| Pressed | Native button style; custom ChatGPT button uses pressed outline | Keep control-specific feedback; `Opacity.pressed` is not a universal button recipe |
| Selected | Native lists and AppKit token controls; custom attachment/newsletter/calendar selections use their own accent/tint recipes | Preserve foreground, active/inactive window state and selection visibility together |
| Accepted drop | Accent tint with existing drop target handling | Pair visible feedback with the existing drop eligibility behavior |
| Focus | Native focus rings; `ternOutline(focus:)` uses width 2 | Keep keyboard operation and avoid clipping rings |
| Disabled | Native `.disabled`; custom brand control uses `.5` opacity | Preserve disabled behavior, not just reduced opacity |
| Loading/pending | Native progress indicators, disabled actions and status text | Preserve layout and meaningful labels; loading is not a separate global color |
| Error/warning/success | Semantic status color with text/symbol; native destructive roles and confirmations | Preserve meaning without depending on color alone |
| Increase Contrast | `ternOutline` strengthens to primary; badges use label ink; calendar transforms and analytics outlines adapt | Inspect the component in context, including selected rows |
| Reduce Motion | `ternAnimation` disables animation transactions; `ternTransition` becomes identity; hover stops animating | Route custom transitions through these policies |
| Sidebar sizing | `Control.sidebarIconScale` follows system sidebar row size | Preserve system sizing rather than forcing a universal row height |
| Text size | Native styles, message-list font metrics and reader scale (0.85–1.5) | Keep user-controlled reading scale distinct from UI density |

Native `Button`, `Menu`, `Picker`, `Toggle`, `TextField`, `List`, `Form`, sheets and popovers own much of their visual behavior. The native-controls tab records these uses. Native materials, SF Symbols and `NSWorkspace` file icons are platform resources, not missing hex or image tokens. The sidebar uses the AppKit sidebar material behind the window and follows window activity.

## Local contracts to refine

Local values and visual expressions in the catalog are review candidates, not automatic violations. Zero padding, flexible frames, layout math, and semantic `.secondary` are often intentional. The scanner cannot determine that meaning on its own.

| Priority | Area | Evidence and next decision |
| --- | --- | --- |
| 1 | Component geometry ownership | Mini-month derives metrics from `Settings.rowHeight`; attachment columns reuse sidebar widths; task aids reuse conversation header sizes. Introduce component roles when those values should be adjustable independently. |
| 1 | Typography role coverage | Shared primitives now use `Typography`; assistant fonts have their own roles; feature views mostly name native styles directly. Agree which roles should span features before migrating them. |
| 1 | Custom selection | Attachments, newsletter rows, calendar cells and recipient suggestions have distinct recipes. Compare each with native selection before choosing shared roles. |
| 2 | File-type color roles | Move `AttachmentPresentation.tint` into a named role family if other surfaces need the same mapping. Preserve file identity independently from status meaning. |
| 2 | Calendar appearance | `CalendarColor` uses dark lift 1.25, floor .55 and contrast saturation 1.2. Review provider-color legibility in both appearances before changing these parameters. |
| 2 | Calendar geometry | Mini-month cells 30, grid 236, overall height 272; timeline hour/gutter 64, minimum day width 96, event height 24. Decide which are component tokens and which remain calculated geometry. |
| 2 | Native text compensation | Recipient token fragment padding 2 and suggestion row height 36 follow AppKit geometry. Change only after checking text baselines and selection rendering. |
| 3 | Materials and elevation | Native panels own most elevation; `Shadow.md` is explicit overlay chrome. Avoid applying it to every card. |
| 3 | Interaction policy | Calendar scroll thresholds and idle timing belong to navigation behavior; settings debounce and toast duration are presentation policies. Keep these categories distinct from visual scales. |

### Email, compose content, and print

The scanner also records app-authored CSS in Swift string literals. HTML email defaults to a 13 CSS-pixel system font and zero body inset. The HTML wrapper starts with white/black; the plain-text wrapper uses `Canvas`/`CanvasText`. Reading preferences scale the body. Dark-mode adaptation transforms sender content in `MessageDocument+DarkMode.swift`.

Print uses a separate recipe: 12-point body, 14-point headings, 10-point metadata in `#444`, black on white, and 24-point gaps between messages. SwiftUI points, CSS pixels, print points and ratios remain separate units. Outgoing attributed-text fonts and sans/serif/monospaced choices are authored message content. A shared UI typography change must not rewrite sent mail.

The scan covers repository-authored styles, not live email HTML, user data, generated image pixels, or values returned by providers. No accounts or messages are needed to regenerate it.

## Using and maintaining the inventory

Choose a semantic/component role first, then use a shared scale value for simple geometry. Keep equal values under different roles when they have different reasons to change. Add a new role beside related definitions, document its purpose, and adopt it in the relevant component. Avoid creating an unused alternate theme.

```swift
Text(title)
    .font(Tokens.Typography.sectionTitle)
    .foregroundStyle(Tokens.Text.primary)
    .padding(Tokens.Space.s4)
    .ternSurface(radius: Tokens.Radius.lg)
```

Regenerate after source changes:

```sh
python3 scripts/design-token-inventory.py
python3 scripts/design-token-inventory.py --check
open docs/design/catalog.html
```

`--check` detects drift in the generated JSON and catalog. It is a maintenance command, not an added CI gate. The scanner's coverage and limitations are embedded in both outputs. Observed reference counts are lexical evidence; aliases, inherited styling and runtime behavior still require source review. An entry with no observed uses is a review candidate, not proof of dead code.

When refining a component, inspect light/dark appearance, increased contrast, keyboard focus, selected/inactive states, Reduce Motion, narrow layouts, and long text where relevant. Build the app and use the existing focused layout/interaction tests for affected behavior. The inventory itself does not certify contrast or render every screen.

This baseline includes 14 new text, typography and action roles used by badges, avatars, empty states and popup headers. Broader adoption, visual tuning, and token renames are the next refinement pass; they are recorded above rather than applied as an app-wide redesign.
