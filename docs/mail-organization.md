# Organize Mail

Organize Mail suggests categories from the selected Google account's most recent 250 received and sent messages combined. Open **Settings → Organize Mail**, choose an account, and select **Analyze recent mail**. The account must be enabled for the assistant and ChatGPT must be connected with an available model.

The analysis uses senders, recipients, subjects, dates, existing labels, and bounded message previews. It does not download bodies or attachments. This information goes to the connected ChatGPT account when analysis starts. Gmail supplies a recent listing window; Tern sorts that window by message date. Drafts, spam, trash, and chat messages are excluded. A smaller mailbox uses the messages available, and the review reports incomplete reads.

The analysis screen shows label lookup, message selection, and the number of messages checked. During ChatGPT analysis, a separate step and elapsed timer remain visible without an estimated percentage. **Cancel** or Escape discards the analysis. Nothing changes in Gmail during this step.

Suggested labels appear as cards with message counts, a short explanation, and an existing/new label indicator. Expand a card to edit its name, inspect sender, subject, date, and preview examples, or choose an eligible future-mail rule. Examples remain available when a label is unchecked and after applying. **Select All** and **Deselect All** change the selection; **Start Over** discards the review. The footer shows the selected labels, unique messages, and filters before **Apply to Gmail**.

Existing user labels are reused by name. Applying adds labels to the selected sample messages. It does not archive, delete, mark messages read, or remove existing labels.

Categories with consistent recurring senders can also create Gmail filters. Each filter adds its category label to future incoming mail from an exact sender. Filters require Gmail Settings permission in **Connections**. A proposed sender must appear in at least two incoming sample messages, and all incoming messages from that sender in the sample must belong to that category. Mixed senders and one-off messages do not qualify.

Action and Waiting describe the reviewed sample. They require evidence of a request or expected reply, use the latest sampled message in a conversation, and do not create recurring sender filters. They do not automatically clear when a reply arrives. Analyze again to review newer mail; previously applied labels remain until removed through normal label controls.

The labels and filters are saved in Gmail, so they also work in Gmail's website and other mail clients. Gmail filters handle incoming messages; they do not infer whether a conversation needs a reply. See [Google's filter guide](https://developers.google.com/workspace/gmail/api/guides/filter_settings).

## Delivery and recovery

Apply saves one account's selected changes to Tern's existing action queue. Label creation runs before message labeling and dependent filters. The review distinguishes queued work from confirmed delivery and failed changes. A network interruption can leave work queued; it is retried by the normal sync engine. Failed changes can be inspected and retried in **Settings → Failed Changes**.

Delivery progress counts queued changes, which can include label creation, message labeling, and filters. The completion summary shows only the labels and messages selected for that application. If a saved action can no longer be confirmed, check the account in Gmail before starting again. **Back to start** leaves the delivery screen; accepted queue work continues.

Analysis results remain in memory. Leaving the pane, switching accounts, or changing assistant access, the ChatGPT connection, or the selected model clears the review. Ordinary message metadata remains in the mail cache. Changes already accepted into the action queue retain the user's Apply instruction and continue through normal delivery. If Tern knows a newer conversation message arrived after an Action or Waiting suggestion, Apply asks for a new analysis.

## Implementation

- `SyncEngine.organizationSamples` reads a bounded Gmail metadata sample, checks access around progress callbacks and responses, and upserts metadata without replacing threads or advancing the history cursor. Sampling progress counts attempted reads, including unavailable messages.
- `MailOrganizationAnalyzer` calls the existing AI provider with a JSON schema and no tools. It treats mail and label text as untrusted data, bounds the request and response, and validates category membership and rule sender evidence. When necessary, it shortens previews and optional context to fit the provider's complete 512 KiB request limit while retaining all sampled messages.
- `SyncEngine.applyOrganization` validates the selected plan and account, adopts existing labels, and queues additive message and filter changes together. Filter payloads participate in temporary-label resolution and cross-lane queue ordering.
- `MailOrganizationModel` binds a review to the account instance, assistant permission revision, ChatGPT connection revision, and selected model. Late progress callbacks cannot restore a canceled or superseded analysis. Its UI edits do not call Gmail until Apply.

Tests cover the 250-message bound, mixed received/sent samples, incomplete reads, revoked access, invalid model output, sender-rule evidence, label dependencies, duplicate prevention, and delivery outcomes. Google API behavior follows the [message listing](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list) and [message label modification](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/batchModify) contracts.
