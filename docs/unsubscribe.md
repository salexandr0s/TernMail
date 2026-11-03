# Newsletter unsubscribe

Open **Unsubscribe** in the mail sidebar. The page opens in its own window and includes every connected account. Use the account picker to focus on one inbox, search by sender or list, and sort by message count, date, or name.

The checkbox above the list selects the visible subscriptions that support direct unsubscribe. Review the selection, then send the requests together. Each result is saved separately, so one failed request does not discard the others. **Pause** saves scan progress; **Stop** stops a batch from starting another request. A request already sent may still take effect.

Senders that require a website visit or an email have individual actions. Email requests open an editable draft from the receiving account. After following the sender's instructions, mark the subscription completed. Opening a link or draft alone does not count as completion. Failed direct requests also offer the sender's manual option.

## What the list shows

- Sender name, address, and mailing-list identity when provided. Different lists and receiving accounts remain separate.
- Newsletter messages found and the latest matching subject/date. Counts cover the inspected messages. Large totals use compact notation; hover or use a screen reader for the exact count.
- Request status, manual completion, and an indicator when newer mail arrives after an unsubscribe request.
- Sender photos or website logos using Tern's existing avatar settings. Display options includes **Show sender logos**; initials appear when no image is available. Logo requests share the existing app-wide preference.

The scan reads received-message metadata in bounded pages. It excludes sent mail, drafts, spam, trash, and chats; it does not fetch message bodies or change read state. Results appear during the first scan. A refresh keeps the previous scan visible until its replacement finishes, and the footer distinguishes scan progress from completed coverage. Refresh again to include newer mail or reconcile messages removed since the last scan.

Request history belongs to the subscriptions present in the current scan. Existing mail stays in place. A successful request means the sender accepted it; the sender controls when delivery stops. **Move back to active** in a row's menu lets the user review a subscription again.

## Delivery and persistence

Direct unsubscribe follows [RFC 8058](https://www.rfc-editor.org/rfc/rfc8058.txt): an HTTPS POST with the fixed `List-Unsubscribe=One-Click` form body. Eligibility requires one unambiguous list URL and matching Gmail DKIM verification for a signature covering both unsubscribe headers. Missing or ambiguous authentication leaves the manual option available.

The transport has no Gmail authorization, cookies, credential storage, cache, or redirects. It validates public hostnames and DNS answers, bounds DNS/network time, and stops receiving after the response headers. Like the existing logo transport, URLSession performs its own DNS resolution after preflight; resolution is not pinned. URL and mailto parsing reject unsupported schemes, private literal hosts, embedded credentials, and injected email headers.

SQLite stores the inspected message index, resumable scan checkpoint, and per-subscription outcomes. Claims prevent duplicate concurrent submissions. Interrupted or uncertain requests require an explicit review before retrying; Tern never replays them automatically. Account removal cancels work and clears its newsletter data. Error text does not expose unsubscribe tokens or message content.

## Verification

Focused Core tests cover parsing and authentication, exact requests and network failures, scan pagination and refresh, account isolation, message counts, duplicate claims, cancellation, cleanup, and persistence failures. App tests cover selection, partial outcomes, manual completion, scope changes, and drafts in the receiving account. Native rendering and interaction checks cover light/dark and compact layouts, mixed selection, and review/manual sheets. The optional `--unsubscribe-keyboard-live` audit checks Space with actual native input because the Xcode test host cannot reliably activate its window. Evidence is kept under `build/Verification/unsubscribe/`.
