# Message reader design

Date: 2026-11-02

The reader presents the subject, a compact summary, and the original messages in that order. Message identity, disclosure, and actions have separate targets. Spacing, control sizes, radii, and motion use the existing native design tokens; colours and typography follow macOS appearance and accessibility settings.

## Message headers

- Put the disclosure before the avatar and sender. Use a second, quieter line for recipients or the collapsed preview.
- Show full sender, To, Cc, Reply-To, timestamp, optional size, and tracking-image information in message details. Long addresses wrap and retain their account-specific address menus.
- Keep More visible at narrow widths. Collapse secondary quick actions into its shared native menu.
- Use the same message commands from More and right-click, including Mark Unread from Here. Preserve draft editing, recipient-aware reply, sent-message Send Again, sharing, export, and original-message access.
- Provide Expand All Messages and Collapse All Messages in the conversation menu. Disable print/export individually while bodies are unavailable.
- Bound the reading column with `Tokens.Layout.readableWidth`; reduce card radius and label weight without changing authored email content.

## Click and keyboard behaviour

| Input | Result |
| --- | --- |
| Single click on a collapsed header background | Expand |
| Single click on an expanded header background | Keep open |
| Double click on a collapsed header background | Expand once |
| Double click on an expanded header background | Collapse once |
| Disclosure button | Toggle |
| Address or action control | Run its own action only |
| Double click in the email body | Preserve text selection |

The header uses AppKit click counts, which follow the system double-click setting. It records whether a sequence began expanded so that the second click cannot undo expansion caused by the first. A drag does not toggle. The native overlay excludes the measured bounds of SwiftUI buttons and menus, so each control receives its own clicks. Left/Right keep their existing expansion commands, Space pages, and a mouse toggle establishes the focused message. Collapsing retains a reachable header near the end of a long conversation.

## Summary

- Start with two lines of overview text and compact Tasks/Decisions disclosure rows. Each populated section has a full-width toggle and count; empty sections are omitted. The overview has its own Read more control only when clipped.
- The AI summary heading minimises the whole card to one bar. Reopening restores the chosen sections. A separate Expand All/Collapse All control handles every available section and the full overview; Collapse All leaves the overview visible.
- Keep source and options controls in the header, including when minimised. Partial coverage remains visible as a labelled info icon in the minimised header and a caption in the open summary.
- Expanded tasks use compact numbered rows with wrapping descriptions, owner labels, and localized due dates. Due dates stay on their original calendar day in every time zone. Number badges and extra row padding are removed.
- Group tasks with separators; use a separate collapsible bullet list for decisions. Each item retains its own source control and contextual accessibility label. Task numbers indicate list order and do not imply priority or completion state.
- Retain the current report while refreshing the same content and access identity; show refresh errors beside it. Discard it immediately when that identity changes.
- Keep asynchronous lifecycle ownership on a stable container when switching between loading and content.
- Ask for one or two sentences, about 45 words at most. Omit routine no-action endings while preserving material explicit instructions not to reply or act.

## Body and image presentation

Retain lazy body realization, Find/source navigation, cached rendering, and sender image preferences. Preview cleanup uses bounded local text and removes only known leading boilerplate.

Blocked or missing images receive a reason label in a generated local SVG on the original image element. This preserves parent selectors, authored dimensions, block flow, links, and meaningful alt text. Remove confirmed tracking-image elements while retaining their count. Loading images once and allowing a sender remain distinct actions; tracking images stay blocked.

The retained Mail and Calendar panes put the active pane above the inactive one. This targets the calendar tooltip appearing over the reader while preserving both panes' state. Native switching and hover verification determine whether it resolves the reported symptom.

## Verification

Use synthetic in-memory accounts for native tests and inspection. Exercise native click-count events through the actual header hit target, child controls, context/overflow parity, keyboard expansion, initial unread/newest expansion, and narrow layout bounds. Capture the reader and summaries in light and dark appearances, plus increased contrast. Cover summary loading-to-content stability, source access, viewport/Find behaviour, and rendering privacy with focused existing tests.

The focused native and Core tests pass, and the final light/dark captures have been inspected. Build and test results are recorded in the session handoff. The specific calendar tooltip hover symptom remains unverified; native pane-retention tests pass.
