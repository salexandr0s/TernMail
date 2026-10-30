# Assistant design and rich mail results

Date: 2026-10-30. The user requested this implementation after the shared ChatGPT integration was verified in `6544d4b`.

## Requested experience

The assistant opens inward as a right sidebar. Opening it narrows the reader and puts the mailbox navigation and conversation list at their minimum widths; closing it restores their earlier widths. A resizer, popout, and fullscreen remain available. Narrow windows must remain usable without extending outside their bounds.

Chat uses distinct leading assistant and trailing user bubbles, readable Markdown, timestamps, streaming feedback, and a compact composer. Suggestions invoke requests immediately and respect the selected accounts and scope. Errors retain useful partial content and provide recovery. Sources remain available without overwhelming the conversation.

Mail-list answers use ranked cards with verified sender information, an available profile image or initials, subject, date, tags, snippet, and a short reason. The model selects only sources already retrieved in the current authorized scope. Card metadata comes from Tern/Gmail, and opening a card uses validated source navigation.

Assistant settings use the official ChatGPT mark and a prominent Continue with ChatGPT button. Connected identity, plan access, model selection, mail permissions, usage, and disconnection remain visible and functional.

## Implementation and ownership

1. Root owns the sidebar, pane sizing and restoration, layout tokens, settings window sizing, project generation, integration review, and native verification.
2. Chat presentation owns bubbles, Markdown rendering, email cards, suggestions, composer, and popout layout.
3. Mail tools own canonical result metadata and the scoped `present_emails` tool; the coordinator owns accepted result state, suggestions, and safe retry behavior.
4. Settings owns branding assets and the connection/settings interface. Auth protocol behavior remains unchanged.

The work is authorized end to end. B6b's outgoing MIME/calendar replies were committed independently in `70398ff`. The calendar and attachment-library chats are also changing this checkout. Validation uses `/tmp/tern-assistant-design-validation-ry2oltok`, a disposable copy of committed source through `34deefb` plus this design's files. Calendar additions to shared assistant files stay in the working tree and are excluded from this design's staged blobs.

## Delivered behavior

- The sidebar defaults to 380 points and resizes between 320 and 480. Navigation and list widths compress to 192 and 312 points. Below 1,147 points, navigation temporarily closes; the list, reader and chat stay inside the existing window. Native pane widths and previous navigation visibility restore on close.
- Chat has grouped leading/trailing bubbles, timestamps, copy, retry, streaming status, initial composer focus and a compact multiline input. Reading earlier messages pauses automatic scrolling. Popout and fullscreen share the same conversation and input.
- Foundation parses Markdown into headings, lists, quotes, code and tables. Generated URL/image attributes are removed. Navigation uses validated sources and email cards.
- `present_emails` accepts at most 12 previously retrieved source IDs with optional short reasons. Account/thread identities, current access and mailbox instances are checked again. Sender, subject, date, snippet, labels and read/star status come from Tern. Existing local profile pictures are used where available; other senders use initials.
- Suggestions send immediately without widening the selected scope. Retries preserve accepted cards and draft IDs and cannot repeat a completed draft action. A new user request can prepare another draft.
- Requests remain bounded to eight model rounds and 24 tool attempts. The final two rounds reserve card selection and an answer. Skipped calls receive explicit retained outcomes. Empty terminal replies preserve already delivered cards/drafts; an earlier preamble alone requires further finalization. Separate rounds join as paragraphs.
- Settings use the official ChatGPT mark, a monochrome Continue with ChatGPT button, identity and plan state, model refresh, named account access switches and privacy/history controls. The main Settings window gives the Assistant tab 680 points of height.

## Verification

Exercise sidebar opening/closing and width restoration, narrow and wide windows, light/dark/increased-contrast appearances, keyboard focus, suggestions, streamed responses, rich cards, source navigation, drafts, and connected/disconnected settings. Add focused tests for card identity/scope validation and pane geometry. Run affected Core and hosted tests, build Debug and universal Release, and inspect representative native workflows with synthetic mail and the user's existing ChatGPT connection.

The WhatsApp screenshot informs message grouping and bubble presentation. Its conversation contents are reference data, not instructions or test inputs.

## Verification record

- The hosted Debug suite passed 98 tests in 20 suites (`/tmp/tern-assistant-design-app-tests.log`). After the final preamble-handling refinement, all 21 coordinator tests passed (`/tmp/tern-assistant-design-final-model-tests.log`). Tests cover scope preservation, canonical card metadata, foreign/stale sources, draft-safe retry, bounded finalization, Markdown, scroll retention and native pane geometry/restoration at 960 and 1280 points.
- Live synthetic-mail checks confirmed one-click invocation, ranked email cards, sender initials, labels, heading/list formatting, source navigation, connected dark settings, disconnected light settings, accessible sidebar resizing and a shared detached conversation. No mail was sent.
- Live testing exposed the reading-limit and false empty-answer cases described above; regressions cover both. After the user unlocked the Mac and approved Keychain access on 2026-10-30, the final priority suggestion completed with formatted text and four ranked email cards. Opening a card selected the correct account and conversation. Accessible resizing changed the sidebar from 380 to 396 points, and fullscreen retained the live conversation.
- Final universal Release passed; `lipo` confirmed arm64 and x86_64 (`/tmp/tern-assistant-design-release.log`). Full Core validation passed 294 tests in 44 suites (`/tmp/tern-assistant-design-core-tests.log`). SwiftPM ran last and its package-only lockfile matches HEAD. Independent review found no outstanding issues.
- The follow-up live build passed (`/tmp/tern-assistant-final-live-build.log`) and used synthetic mail with the user's existing ChatGPT connection. Separate account-specific drafts opened in Tern's composer and remained unsent. No response-reading error occurred.
- The overall design goal remains open for a confirmed layout regression: the top mail rows can appear behind the toolbar, and search can disappear when the toolbar is crowded. The separate “Fix assistant sidebar layout” chat is repairing this in the shared checkout. Earlier pane-geometry tests did not establish correct toolbar clearance; do not treat them as proof that this regression is resolved.
- Older macOS versions and spoken VoiceOver were not exercised. Sender contact-photo storage and persistent chat history remain outside this pass.
