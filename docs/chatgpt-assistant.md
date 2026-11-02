# ChatGPT assistant

Tern uses Sign in with ChatGPT to connect its assistant to your ChatGPT plan. Model choices come from the connected account. No OpenAI API key or Codex installation is needed.

## Connect

1. Open Tern, then **Settings → Assistant**, or **Assistant Options → Assistant Settings…** in the assistant's header.
2. Choose **Continue with ChatGPT** and finish signing in in your browser. Grant ChatGPT plan usage when offered. An identity-only connection cannot run the assistant.
3. Enable the mail accounts the assistant may use and choose an available model.
4. Open the assistant and ask a question. Mail scope starts at **All enabled accounts**. Choose **Mailbox accounts** or **Selected conversations** to narrow it; New Chat keeps your current choice.

Choose a suggestion to ask immediately, or write a request such as “What needs my attention this week?” Suggestions respect the selected scope. Summary and draft suggestions require selected conversations; drafting requires one conversation. Open an email card or source to read the supporting conversation. **Review Draft** opens the normal Tern composer for editing and sending.

The assistant can search mail, read threads, extract supported attachments, and prepare drafts. Search results are paginated and subject to request limits; a single request does not read an entire mailbox. The initial attachment reader supports plain text, CSV, Markdown, JSON, XML, and PDFs with selectable text. Files are limited to 5 MB; extraction is limited to 60,000 characters and 40 PDF pages. Scans need OCR, which is not included.

Broad requests review a bounded selection of conversations. Tern reserves the end of each request for displaying relevant emails and answering from the results already gathered; replies should identify incomplete coverage.

## Tasks and events in responses

Ask “What are my todos from my recent mail?” to get task cards with owners, stated due dates, and supporting email excerpts. **Add to Tasks** opens a review where you can edit the title, notes, and due date and choose a list in the email's account. Saving uses Google Tasks; the card shows **Added to Tasks** after confirmation. If a save response is lost, **Check saved task** opens a review. **Check again** searches for the existing task; **Add Again…** requires explicit confirmation before another addition.

Ask “When are these events?” or use **Find events in my mail** for event cards. Each card shows its date, time zone, location, and source. **Add to Calendar** opens the normal editable calendar review; only its Save action adds the event. Dates that are missing stay marked **Date to be confirmed**, and a missing duration is identified for review. All-day dates retain their calendar day across time zones. Events already retrieved from Calendar offer **Open in Calendar**.

Task and event cards require sources the assistant has read. Reading or listing them does not save tasks, book events, or send invitations. Later replies should be checked for completed tasks, rescheduled meetings, and cancellations. Source excerpts help you verify each result; generated titles and interpretations still need review.

Responses support headings, nested lists, quotes, checklists, tables, code, and small flowcharts. Text checkboxes display reported completion and are read-only; task cards provide the save controls. Tables become labeled rows when the sidebar is narrow. Copying a response includes its task and event details, and copying a checklist preserves its checked state.

## Write in the compose window

Choose **Ask AI** in a compose or reply window, or press **Shift-Command-J**, to open a small chat bar below the message editor. In narrow windows the toolbar shows its sparkle icon. Ask for a reply, a revision, or an invitation such as “Invite her to dinner next Friday.” The assistant uses the current unsaved draft, recipients and reply thread. It can search other mail in the sending account and check calendars you have allowed in Assistant Settings. Changing the conversation selected in the main window does not change this context.

**Review Draft** shows the suggested subject and body alongside the conversation. Ask follow-up questions in the same panel, then choose **Apply to Draft** to replace the message text. **Undo** restores the previous rich text while no later edits have been made. Recipients, signatures, quoted messages and attached files stay in the draft; inline images move below the rewritten text. If you edit the draft after requesting a suggestion, ask for an updated suggestion before applying it.

For invitations, the assistant can check an explicit evening or weekend interval as well as working-hours availability. It should state the date, timezone and any assumed time or duration. Missing calendar access or failed checks remain unknown. Suggestions reserve no time, create no events and send no mail. Review the draft and use the usual Send button when ready.

Each compose window keeps its own conversation in memory. Closing the assistant stops the current response, returns to your place in the message, and keeps the conversation available until the compose window closes. **New Chat** clears it. Starter prompts fill the input so you can edit them before asking. Removing access clears retained context and suggestions. **Stop response** cancels a request; **Try Again** repeats it using the current draft.

Drop files onto the AI bar or its conversation to use them as **AI context**. These files appear separately from email attachments and are supplied to the assistant when you ask. Dropping files elsewhere in the compose window, including the message editor, adds them to the outgoing email instead. The drop target identifies which destination will receive the files.

AI context accepts up to four files, each up to 5 MB: plain text, CSV, TSV, Markdown, JSON, XML, PDFs with selectable text, and supported images. Text excerpts are limited to 12 KB per file; PDF reading inspects up to 40 pages. Images use a reduced first-frame preview, so small text and fine details may be lost. Combined context is limited to 60 KB. Files that cannot be read show a reason and Retry/Remove controls. Removing a context file starts a new chat to clear its contents from the conversation. Adding files keeps the existing chat.

## Conversation summaries

Opening a conversation generates a short AI summary below its event cards when ChatGPT, a model, and the account’s assistant access are ready. The current assistant scope still applies. The summary sits in a subtle translucent card matching the events above it and shows up to three lines; **Details** reveals the full text, decisions, open tasks, and supporting messages. Source links expand and scroll to the original message. Tasks are extracted from the conversation and do not change mail or create reminders.

Summaries automatically use GPT-6 Luna when the connected account lists it, then GPT-5.4 mini, then the selected chat model. This preference keeps summaries on a small, efficient model when one is available. Chat, calendar interpretation, and writing-style learning use the model selected in Assistant settings.

Use **Summary Options → Refresh Summary** to generate it again, or **Retry** after a failure. New messages trigger a fresh summary. Reading, starring, labeling, and loading message bodies do not regenerate an unchanged conversation. Up to 16 summaries stay in memory for revisiting conversations; they are discarded on access loss, account replacement, connection or model changes, and app exit. Summaries do not enter chat history or persist to disk.

The reader shows a coverage note when the mail read omitted messages or content. If Gmail returns a different message set from the open reader, sync mail and retry. Generated source references must match the retrieved messages before Tern displays the result.

## Learn your writing style

Once ChatGPT, a model, and mail access are ready, Tern learns a separate writing profile for each enabled mail account. It inspects up to 100 recent sent messages and sends bounded excerpts of your authored text to ChatGPT. Common quoted exchanges, forwarded messages, and signatures are removed first; this filtering is a heuristic and can miss unusual formats. Ordinary attachments are not used for learning.

The profile records tone, length, greetings, closing patterns, formatting, and observed languages. It contains no saved excerpts or message facts. Profiles stay on this device and survive ordinary reconnection. A draft uses the profile for its sending account, follows the current conversation's language and recipient context, and gives your explicit instructions priority. Learning does not change the assistant's chat voice or send mail.

Open **Settings → Assistant → Writing style** to see progress and the number of samples used. **Relearn** refreshes the profile from sent mail. Turning off learning deletes that account's profile; removing its assistant mail access also deletes it. Accounts with fewer than five usable samples or too little authored text show insufficient evidence rather than a guessed profile.

If a draft is requested during learning, Tern waits briefly for the profile before creating it. When learning is still running, it reports that no draft was created. If learning failed or there is too little evidence, drafts can still use the current conversation; Tern reports that the personal style was unavailable.

## Chat controls and data

Use the Assistant button at the far right of the window toolbar to open or close the sidebar. It stays in the same place in Mail and Calendar.

The assistant opens as a right sidebar inside the existing window. Mailbox navigation and the conversation list shrink while it is open. At narrow widths, mailbox navigation temporarily closes. Closing the assistant restores the earlier layout. Drag its left edge to resize it; the width is kept across launches. Press Esc to close it while the message field is empty. **Assistant Options → Open in a Window** or **Open Full Screen** moves it to a separate window or full screen. All three views share the conversation and unfinished message.

The header shows the current model. Use the mail scope menu to choose which conversations to include, and the sliders button beside it to manage mail and calendar access. The welcome panel shows any setup step still needed, followed by suggestion cards with short descriptions. A new chat opens at the top of this panel, including in short windows.

Press **Return** to send and **Shift-Return** to insert a new line. **⌘ Return** also sends. Your messages appear in trailing bubbles, while assistant replies use the conversation width for text and email cards. Copy controls remain beside message timestamps. Control-click a reply for Copy, Copy as Markdown, Copy as Plain Text and Retry.

Replies lead with the answer and default to short paragraphs or a few useful bullets. Ask for more detail when you need it. Headings, lists, emphasis, quotes, code, and tables have distinct formatting. Small workflows and decisions can include an embedded flowchart; its controls reveal or copy the diagram source. Unsupported or unfinished diagrams remain readable code.

Email cards show verified sender details, dates, labels, unread/starred status, and a reason for inclusion. Available local profile pictures appear beside senders; otherwise Tern shows initials. Cards link to the original conversation. Generated text, images, and diagrams do not create navigation links; use the validated cards and sources.

**Stop response** cancels the current request. **Retry** repeats a failed reply while keeping email cards and drafts already created. Retrying cannot create another draft after one has succeeded; ask in a new message to prepare another. **New Chat** clears the conversation. Chat history stays in memory and is discarded when Tern quits. Scroll up to read earlier messages without following new output; **Jump to Latest** resumes following it.

Mail access starts disabled. Relevant content from enabled accounts is sent to OpenAI for your requests, automatic summaries and event interpretation in permitted open conversations, and writing-style setup when learning is enabled. Changing the effective scope or removing access clears retained chat content and cancels active work. Reading mail through the assistant does not mark it read. Sending remains an action in the compose window.

Tern stores its own ChatGPT connection in macOS Keychain, separate from Gmail and other apps. **Disconnect…** asks first, then clears local authorization and requests remote revocation. If revocation fails, Tern reports it; local use remains disabled. **Manage Usage** opens ChatGPT's usage controls.

## Calendar access

Connect Google Calendar through an existing Tern Google account, then open **Settings → Calendar**, or choose **Manage Calendars…** in Calendar. Each calendar has independent assistant access: **Off**, **Availability Only**, or **Event Details**. Access starts Off. Showing a calendar in the sidebar does not grant assistant access. Select scheduling calendars separately and review working hours and time zone.

The assistant can check availability, read permitted events and prepare editable event proposals. It cannot save a calendar change through a tool call. Open a proposal, review its fields and invitation recipients, then choose Save. Changing calendar access cancels active requests and discards retained calendar context and proposals.

For a scheduling reply, select the times you want to suggest. Tern checks them again and asks the assistant to prepare an editable email draft. Choosing times reserves no event and sends no email. Calendar failures remain unknown; Tern does not treat an inaccessible calendar as free. Replies contain the chosen times without the titles or reasons for other appointments.

Ordinary dated emails can offer Add event with AI disabled. Optional AI interpretation runs when an allowed conversation opens and can prepare revised meeting suggestions. All suggestions use the same reviewed event editor. See [Calendar integration](plans/calendar-integration.md) for Google setup, implementation limits and verification.

## Troubleshooting

- **Keychain access unavailable:** Tern opens while saved connections load in the background. If access fails, open Settings → Assistant and choose **Retry Keychain Access**. This retries the saved connection without starting a new browser sign-in.
- **Plan usage not enabled:** reconnect and grant plan usage. Availability depends on the ChatGPT account and the current Sign in with ChatGPT preview.
- **No models or usage limit:** refresh the model list or open **Manage Usage**. Tern does not substitute an API-key connection.
- **Sign-in interrupted or expired:** start sign-in again. Keep Tern open while the browser returns to the temporary local callback.
- **Mail access changed:** select the intended accounts and scope, then start a new request.
- **Context or reading limit:** narrow the request or start a new chat. Completed drafts remain available in Drafts.

## Implementation references

The independent Swift implementation follows the [official cookbook](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt), [devkit](https://github.com/openai/sign-in-with-chatgpt-devkit), and current [models and inference contract](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference). Gatekeeper's connection lifecycle was used as a local design reference. The devkit is not bundled.

The shared `TernAI` Core module handles authentication, model discovery, streaming Responses, namespaced tools, and structured output. The app supplies Keychain storage, browser sign-in, account permissions, attachment extraction, and conversation state. SyncEngine supplies bounded mail reads and queued draft creation. Reader summaries use a separate read-only tool session, validated structured output, and a memory cache independent of chat. `AssistantModel.summarize(thread:)` remains available for callers that need the structured result.

For live testing with synthetic mail, launch a Debug build with `--ui-audit --ui-audit-live-chatgpt`. The second flag explicitly enables Tern's ordinary ChatGPT Keychain storage while mail remains synthetic. Without it, audit previews use a temporary connection that ends when the preview quits. Hosted tests always use isolated connection storage.

Add `--ui-audit-writing-style` for 100 synthetic sent messages per account, with informal English and formal German examples. Writing profiles in audit previews stay in memory. See the [writing-style plan](plans/assistant-writing-style.md) for limits and verification.

See the [implementation plan](plans/chatgpt-integration.md) for verification targets and the [feature roadmap](plans/ai-and-features-roadmap.md) for later product features.
