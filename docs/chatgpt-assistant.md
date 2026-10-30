# ChatGPT assistant

Tern uses Sign in with ChatGPT to connect its assistant to your ChatGPT plan. Model choices come from the connected account. No OpenAI API key or Codex installation is needed.

## Connect

1. Open Tern, then **Settings → Assistant** or **Assistant → Options → Assistant settings**.
2. Choose **Continue with ChatGPT** and finish signing in in your browser. Grant ChatGPT plan usage when offered. An identity-only connection cannot run the assistant.
3. Enable the mail accounts the assistant may use and choose an available model.
4. Select a conversation, open the assistant, and ask a question. Change the scope to use the current account or all enabled accounts when needed.

Choose a suggestion to ask immediately, or write a request such as “What needs my attention this week?” Suggestions respect the selected scope. Summary and draft suggestions require selected conversations; drafting requires one conversation. Open an email card or source to read the supporting conversation. **Review draft** opens the normal Tern composer for editing and sending.

The assistant can search mail, read threads, extract supported attachments, and prepare drafts. Search results are paginated and subject to request limits; a single request does not read an entire mailbox. The initial attachment reader supports plain text, CSV, Markdown, JSON, XML, and PDFs with selectable text. Files are limited to 5 MB; extraction is limited to 60,000 characters and 40 PDF pages. Scans need OCR, which is not included.

Broad requests review a bounded selection of conversations. Tern reserves the end of each request for displaying relevant emails and answering from the results already gathered; replies should identify incomplete coverage.

## Learn your writing style

Once ChatGPT, a model, and mail access are ready, Tern learns a separate writing profile for each enabled mail account. It inspects up to 100 recent sent messages and sends bounded excerpts of your authored text to ChatGPT. Common quoted exchanges, forwarded messages, and signatures are removed first; this filtering is a heuristic and can miss unusual formats. Ordinary attachments are not used for learning.

The profile records tone, length, greetings, closing patterns, formatting, and observed languages. It contains no saved excerpts or message facts. Profiles stay on this device and survive ordinary reconnection. A draft uses the profile for its sending account, follows the current conversation's language and recipient context, and gives your explicit instructions priority. Learning does not change the assistant's chat voice or send mail.

Open **Settings → Assistant → Writing style** to see progress and the number of samples used. **Relearn** refreshes the profile from sent mail. Turning off learning deletes that account's profile; removing its assistant mail access also deletes it. Accounts with fewer than five usable samples or too little authored text show insufficient evidence rather than a guessed profile.

If a draft is requested during learning, Tern waits briefly for the profile before creating it. When learning is still running, it reports that no draft was created. If learning failed or there is too little evidence, drafts can still use the current conversation; Tern reports that the personal style was unavailable.

## Chat controls and data

Use the round Assistant icon at the far right of the window toolbar to open or close the sidebar. The button immediately to its left switches between Mail and Calendar. These controls stay in the same position in both views.

The assistant opens as a right sidebar inside the existing window. Mailbox navigation and the conversation list shrink while it is open. At narrow widths, mailbox navigation temporarily closes. Closing the assistant restores the earlier layout. Drag its left edge to resize it, or use **Options** to open a separate window or full-screen view. All three views share the conversation and unfinished message.

Replies support headings, lists, emphasis, quotes, code, and tables. Email cards show verified sender details, dates, labels, unread/starred status, and a reason for inclusion. Available local profile pictures appear beside senders; otherwise Tern shows initials. Cards link to the original conversation. Generated text and images do not create navigation links; use the validated cards and sources.

**Stop response** cancels the current request. **Try again** retries a failed reply while retaining email cards and drafts already created. Retrying cannot create another draft after one has succeeded; ask in a new message to prepare another. **New chat** clears the conversation. Chat history stays in memory and is discarded when Tern quits. Scroll up to read earlier messages without following new output; **Jump to latest** resumes following it.

Mail access starts disabled. Relevant content from enabled accounts is sent to OpenAI for your requests and for automatic writing-style setup when learning is enabled. Changing the effective scope or removing access clears retained conversation content and cancels active work. Reading mail through the assistant does not mark it read. Sending remains an action in the compose window.

Tern stores its own ChatGPT connection in macOS Keychain, separate from Gmail and other apps. **Disconnect** clears local authorization and requests remote revocation. If revocation fails, Tern reports it; local use remains disabled. **Manage usage** opens ChatGPT's usage controls.

## Calendar access

Connect Google Calendar through an existing Tern Google account, then open Calendar → Manage calendars. Each calendar has independent assistant access: **Off**, **Availability only**, or **Event details**. Access starts Off. Showing a calendar in the sidebar does not grant assistant access. Select scheduling calendars separately and review working hours and time zone.

The assistant can check availability, read permitted events and prepare editable event proposals. It cannot save a calendar change through a tool call. Open a proposal, review its fields and invitation recipients, then choose Save. Changing calendar access cancels active requests and discards retained calendar context and proposals.

For a scheduling reply, select the times you want to suggest. Tern checks them again and asks the assistant to prepare an editable email draft. Choosing times reserves no event and sends no email. Calendar failures remain unknown; Tern does not treat an inaccessible calendar as free. Replies contain the chosen times without the titles or reasons for other appointments.

Ordinary dated emails can offer Add event with AI disabled. Optional AI interpretation runs when an allowed conversation opens and can prepare revised meeting suggestions. All suggestions use the same reviewed event editor. See [Calendar integration](plans/calendar-integration.md) for Google setup, implementation limits and verification.

## Troubleshooting

- **Plan usage not enabled:** reconnect and grant plan usage. Availability depends on the ChatGPT account and the current Sign in with ChatGPT preview.
- **No models or usage limit:** refresh the model list or open **Manage usage**. Tern does not substitute an API-key connection.
- **Sign-in interrupted or expired:** start sign-in again. Keep Tern open while the browser returns to the temporary local callback.
- **Mail access changed:** select the intended accounts and scope, then start a new request.
- **Context or reading limit:** narrow the request or start a new chat. Completed drafts remain available in Drafts.

## Implementation references

The independent Swift implementation follows the [official cookbook](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt), [devkit](https://github.com/openai/sign-in-with-chatgpt-devkit), and current [models and inference contract](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference). Gatekeeper's connection lifecycle was used as a local design reference. The devkit is not bundled.

The shared `TernAI` Core module handles authentication, model discovery, streaming Responses, namespaced tools, and structured output. The app supplies Keychain storage, browser sign-in, account permissions, attachment extraction, and conversation state. SyncEngine supplies bounded mail reads and queued draft creation. The same provider and scoped retrieval support `AssistantModel.summarize(thread:)`, which returns validated source references, decisions, and open tasks for future reader features.

For live testing with synthetic mail, launch a Debug build with `--ui-audit --ui-audit-live-chatgpt`. The second flag explicitly enables Tern's ordinary ChatGPT Keychain storage while mail remains synthetic. Without it, audit previews use a temporary connection that ends when the preview quits. Hosted tests always use isolated connection storage.

Add `--ui-audit-writing-style` for 100 synthetic sent messages per account, with informal English and formal German examples. Writing profiles in audit previews stay in memory. See the [writing-style plan](plans/assistant-writing-style.md) for limits and verification.

See the [implementation plan](plans/chatgpt-integration.md) for verification targets and the [feature roadmap](plans/ai-and-features-roadmap.md) for later product features.
