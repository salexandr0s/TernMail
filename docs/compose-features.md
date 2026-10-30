# Composing mail

Settings → Composing has Writing, Templates, Signatures and Suggestions sections. Gmail signatures remain in their own Settings pane.

## Writing

- New messages use the selected mailbox's account. Automatic sender selection in a combined mailbox checks the first recipient's most recent cached exchange. A fixed account or an explicit From choice takes precedence.
- Replies select a verified address from the original To or Cc. Reply All excludes every verified address belonging to that account.
- The default font is sans serif, serif or fixed width. Each draft saves its chosen font.
- Recipient tokens can show names or full addresses. Suggestions combine cached mail, saved contacts, other contacts, groups and the Workspace directory. Local results keep their order when directory results arrive.
- Selecting a group fetches its current members. Tern inserts the expansion together only when every member address is available. An incomplete catalogue is marked in the suggestion; incomplete membership never sends a subset. Sending is blocked while a selected group is loading.
- Typed and pasted Markdown supports paragraphs, lists, emphasis and web/mail links. The setting can be switched off. Writing Tools uses the native editor on macOS 15.1 and later.
- View → Show Formatting and the compose toolbar control the same format bar. Templates can be inserted from the toolbar or Edit → Insert Template.

## Signatures and templates

Templates and local signatures contain rich text and persist in the account configuration database. Files are added while composing.

Signature defaults can apply to an account or override one From address. New messages and replies/forwards have separate choices: None, Gmail signature or a local signature. Placement above quoted text and the `-- ` separator are configurable. Existing drafts keep their saved signature, placement and separator when settings change.

## Images and sending

Pasting or dropping an image into the message body stores its bytes in the managed outgoing folder and saves a stable CID in the document. Uploads use `multipart/related`; retries and account moves preserve the reference. Removing the image from the editor omits its unused resource from outgoing MIME. The attachment button and drops outside the editor add ordinary attachments.

Supported CID images survive draft import, forwarding and Send Again. Cached replies use the corresponding account/message resource bytes when available. Ordinary attachments with Content-ID headers remain attachments. Missing bytes for an authored image stop the upload instead of silently sending a broken image.

Send and Archive records the intent with the draft. The archive action enters the mail queue only after delivery is confirmed. Undo Send cancels the send and clears that intent. Send Again creates an independent draft with copied recipients, subject, supported body formatting and files; it does not reuse the original thread or Message-ID.

## Selected quotes and email links

Ask, Always and Never control quoting selected text. Selection carries its account, thread and exact message identity. Reply actions validate that context before creating the draft. Selected text is escaped when it becomes HTML.

`mailto:` links prefill To, Cc, Bcc, subject and body in an editable draft. Plus signs stay literal. Header line injection and repeated subject/body fields are rejected; unsupported headers cannot change the sender or attach a file. The default-mail-app control lives in General Settings.

## Verification

Core acceptance on 2026-10-30 passed 471 tests across 82 suites, including compose input, MIME, sender/signature preferences, inline resources, Send Again, Send and Archive, Undo and account-boundary regressions. Hosted editor/model checks pass; the final integrated totals and native acceptance limits are recorded in [Milestone 5 verification](milestone-5-verification.md).

Live Gmail delivery and system Writing Tools availability depend on the connected account and Mac. Synthetic tests do not establish those results.
