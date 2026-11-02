# Sender details and analytics

Click a sender's profile picture in the message list or message reader to open their card. It shows received and sent totals, history coverage, first and latest email dates, and links found in available email signatures. The copy button confirms when the email address is copied. The identity and **View analytics** action stay visible while links scroll. **Go > Analytics** opens account-wide analytics.

Analytics keeps account and date filters above the activity totals and chart. Frequent contacts show relative email volume, with received and sent portions, followed by recent emails and read receipts. Narrow windows arrange these sections in one column. The separate **Mail history** date panel uses all indexed history; count cards, contacts, recent emails and the chart use the selected period. Open a recent email to view it in a conversation window. Tern downloads its metadata first if the reading cache no longer has it.

Select a bar to see that period's sent and received counts, or select the table icon to see values and the bar-chart icon to return to the chart. The small charts in the Received and Sent cards share a scale and show the same activity by period. Partial history remains visible beside the totals; history-loading controls and account details are at the bottom of the page.

## History coverage

The index starts with messages already cached on this Mac. **Load full history** adds older Gmail metadata without opening messages or changing their read status. Loading can be canceled and resumed. Completed pages survive restarts and normal cache cleanup.

Expand **History details** for each account's scan date or indexed count. If mail sync is paused, enable **Sync Mail** in Account Settings before loading history.

A completed scan shows its date. Gmail can change during a scan, so this is a dated enumeration rather than an atomic snapshot. Normal sync applies new mail, label changes and confirmed deletions. If Gmail's incremental history expires, coverage becomes partial until another scan reconciles it.

Counts exclude drafts, provisional sends, spam and trash. SENT determines outgoing mail, including aliases; self-addressed sent mail counts once as sent. Sender matching uses exact parsed addresses. To and Cc are indexed; Bcc is absent from the existing metadata model. The same message received by two accounts counts once in each account. Removing an account removes its analytics and receipt data.

## Profile links

Tern extracts links locally from bounded, unquoted signature regions. It supports LinkedIn, Instagram, Facebook, X, GitHub, YouTube, TikTok, Mastodon and websites. It does not search social accounts, upload message content, or infer a profile from an email address. Existing contacts still supply names and photos.

Discovered links may belong to the person or their organization. The link's help text shows the source signature's date. Quoted and forwarded signatures, oversized inputs, unsafe URLs, and common unsubscribe, sharing and tracking links are excluded. If no usable signature body is cached, the card states that no links were found.

## Read receipts

In the compose window's **More** menu, enable **Request Read Receipt**. The option defaults off and persists with the draft. After Gmail accepts the send, Tern keeps a request record for the actual recipients. The sent-message header and Analytics show a confirmation only after a matching displayed receipt arrives. **No receipt yet** means the outcome is unknown.

For messages sent to multiple recipients, expand the receipt summary to see each recipient's status and receipt arrival time.

The receipt date is its arrival time, not an exact reading time. Recipient apps and settings determine whether a receipt is returned; personal Gmail accounts do not provide Gmail's read receipt feature. Strict matching may also omit receipts returned through a separate reporting address. Requests apply to future messages and cannot recover past opens. Tern does not automatically return receipts to other senders.

Receipt downloads use a durable retry queue so a temporary failure does not hold up ordinary mail sync. Matching checks the account, original Message-ID, requested recipient, reporting sender and return address. Receipt data survives ordinary message-cache eviction.

See [Google's receipt limitations](https://support.google.com/mail/answer/9413651?hl=en) and the [message disposition notification standard](https://www.rfc-editor.org/rfc/rfc8098.html). Receipt messages are reports from another mail system, not proof that a person read the content.
