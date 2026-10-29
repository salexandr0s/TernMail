# Milestone 4 plan: integrations

Status: approved 2026-10-29 after a plan review. Research input: the "Google services and authorization" and "Real-time updates" sections and the milestone list in `docs/research/mimestream-behavior.md` (behavior only). Branch `feat/milestone-4`, cut from `feat/milestone-3` at `5d4d385`, which includes milestone 2 at `7c6fbad`.

The milestone runs in two stages. Stage A adds library code in new files and changes no existing file except `Packages/Core/Package.swift`. Stage B wires that code into sign-in, the store, the sync engine, compose, the thread view and Settings. It starts only after you say milestones 2 and 3 are done.

## Scope

In scope:

- A new-mail signal that starts the existing history sync early: IMAP IDLE on INBOX (answered question 1).
- Gmail settings: list, add, change and delete filters; read and change the vacation responder; read send-as identities and edit the signature of the account's primary address.
- Send-as in compose: a From menu with the account's verified addresses, and the matching signature in new messages.
- Contact suggestions from the People API: saved contacts and "other contacts" synced locally, plus a live directory search for Google Workspace accounts, merged with milestone 2's suggestions from cached mail.
- A calendar invitation banner at the top of the thread view, with Accept, Maybe and Decline for invitations sent to one of the account's addresses. Replies go out as emailed iTIP replies.

Out of scope:

- `users.watch` push through Cloud Pub/Sub, which needs a server.
- Adding, verifying or deleting send-as addresses, SMTP relay settings, delegates, forwarding addresses, auto-forwarding, and POP and IMAP settings.
- Creating filters that forward mail, and editing existing ones that do. Tern shows their forward address and can delete them.
- Writing contacts, contact photos and contact groups.
- Adding events to a calendar, free/busy, counter-proposals, a note with an answer, and expanding recurrence rules. The banner says an event repeats and shows the first occurrence.
- System notifications for new mail.

## Google API facts this plan relies on

Checked against Google's reference pages and guides on 2026-10-29: the Gmail API reference (`developers.google.com/workspace/gmail/api/reference/rest/v1/…`) and its scopes and quota pages, the People API reference (`developers.google.com/people/api/rest/v1/…`), Gmail's IMAP and XOAUTH2 guides, the Calendar API reference, the OAuth 2.0 guides for installed apps, and the OpenID Connect guide.

Gmail settings:

- Filters have `create`, `delete`, `get` and `list`, and no `update` or `patch`. A filter is an `id`, `criteria` (`from`, `to`, `subject`, `query`, `negatedQuery`, `hasAttachment`, `excludeChats`, `size`, and `sizeComparison`: `unspecified`, `smaller` or `larger`) and an `action` (`addLabelIds`, `removeLabelIds`, `forward`). Filters act on messages, not threads, and only on mail that arrives after they exist.
- `filters.create` and `filters.delete` accept only `gmail.settings.basic`. `filters.list` returns `{"filter": [...]}` with no paging and also accepts `gmail.modify`, `gmail.readonly` and `mail.google.com`. An account holds at most 1,000 filters. The delete page doesn't say what a missing ID returns.
- `settings.getVacation` accepts `gmail.modify`. `settings.updateVacation` is a `PUT` of the whole resource and accepts only `gmail.settings.basic`. Fields: `enableAutoReply`, `responseSubject`, `responseBodyPlainText`, `responseBodyHtml` (used over the plain text when both are set; Gmail sanitizes it), `restrictToContacts`, `restrictToDomain` (Workspace only), and `startTime` and `endTime` as epoch milliseconds in strings, with the start before the end. An enabled reply needs a subject or a body. The page doesn't say whether omitted fields are cleared.
- `sendAs.list` returns `{"sendAs": [...]}` with no paging and accepts `gmail.modify`. `sendAs.patch` and `sendAs.update` accept `gmail.settings.basic` or `gmail.settings.sharing`. Fields Tern reads: `sendAsEmail`, `displayName`, `replyToAddress`, `signature` (HTML that Gmail sanitizes, "added to new messages composed in the Gmail web UI. It does not apply to replies"), `isPrimary`, `isDefault`, `treatAsAlias` and `verificationStatus` (`accepted`, `pending` or unspecified). The update page says addresses other than the primary one "can only be updated by service account clients that have been delegated domain-wide authority". The patch page says nothing about it.
- Quota units: `filters.create` and `filters.delete` 5, `filters.list` 1, `getVacation` 1, `updateVacation` 5, `sendAs.list` 1, `sendAs.update` 100 (`sendAs.patch` isn't listed), `history.list` 2, `labels.list` and `labels.get` 1. Limits: 6,000 units per user per minute and 1,200,000 per project per minute.

People API:

- `people.connections.list` (`GET /v1/people/me/connections`): `personFields` is required; `pageSize` is 1 to 1,000 (default 100); `pageToken` needs the other parameters unchanged; `requestSyncToken` and `syncToken` give incremental syncs, which return deleted people with `metadata.deleted`. Sync tokens expire 7 days after the full sync. A request with an expired token fails with reason `EXPIRED_SYNC_TOKEN`, and the client then does a full sync. The first page of a full sync has its own fixed quota and returns 429 when it runs out. Changes take minutes to show up. Scope `contacts` or `contacts.readonly`.
- `otherContacts.list` (`GET /v1/otherContacts`): `readMask` is any of `emailAddresses`, `metadata`, `names`, `phoneNumbers` and `photos`; `pageSize` up to 1,000; sync tokens as above. Scope `contacts.other.readonly`.
- `people.searchContacts` and `otherContacts.search` need a warm-up request with an empty query, return at most 30 results and don't page. Same scopes as the lists.
- `people.searchDirectoryPeople`: `query` (prefix match), `readMask` and `sources` (`DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE`, `DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT`) are required; `pageSize` is 1 to 500 (default 100); `pageToken` needs the other parameters unchanged. It returns `people`, `nextPageToken` and `totalSize`. Scope `directory.readonly`. The error a personal account gets isn't documented.
- A person has `resourceName`, `names[]` (`displayName`, `givenName`, `familyName`, `metadata.primary`), `emailAddresses[]` (`value`, `type`, `displayName`, `metadata.primary`) and `metadata.deleted`.

IMAP:

- Host `imap.gmail.com`, port 993, TLS. "The scope for IMAP, POP, and SMTP access is `https://mail.google.com/`."
- XOAUTH2 sends `base64("user=" + address + "\x01auth=Bearer " + token + "\x01\x01")`, on one line as `AUTHENTICATE XOAUTH2 <base64>` when the server offers SASL-IR (RFC 4959). On failure the server sends a `+` challenge holding base64 JSON (`status`, `schemes`, `scope`). The client answers with an empty line, and the server ends with `NO`.
- An IMAP session lasts up to about 24 hours. One opened with OAuth lasts "approximately the validity period of the access token used (usually 1 hour)", and then Gmail closes it.
- Google documents no IDLE timeout. RFC 2177 tells clients to restart IDLE at least every 29 minutes, and one forum report puts Gmail's limit near 15 minutes.
- Only secondary sources say IMAP has been always on for personal Gmail accounts since January 2025. Workspace admins can turn IMAP off.

Calendar and iCalendar:

- The narrowest Calendar scope that can both find an event by `iCalUID` and patch it is `calendar.events.owned`. `events.patch` takes `sendUpdates` (`all`, `externalOnly`, `none`), and array fields, attendees included, replace the stored array.
- RFC 5546: a REPLY carries METHOD:REPLY, exactly one ATTENDEE (the person replying), DTSTAMP, ORGANIZER and UID; RECURRENCE-ID only when it answers for one occurrence; SEQUENCE equal to the request's when that isn't zero; no VALARM. A CANCEL carries DTSTAMP, ORGANIZER, SEQUENCE and UID, and STATUS:CANCELLED when the whole event is canceled. The higher SEQUENCE wins, and on a tie the later DTSTAMP.
- RFC 5545: every VCALENDAR carries VERSION:2.0 and PRODID. A DATE-TIME with a TZID needs a VTIMEZONE for that TZID in the same object. Lines fold at 75 octets with CRLF and one space or tab; parameter values containing `:`, `;` or `,` are quoted; DATE-TIME is floating, UTC (`Z`) or local with TZID; TEXT escapes are `\\`, `\;`, `\,`, and `\n` or `\N`. An all-day event's DTEND is exclusive. A VTIMEZONE rule's DTSTART is local time at the rule's TZOFFSETFROM.
- RFC 6047: the MIME type is `text/calendar` with a `method` parameter equal to METHOD, `charset=UTF-8` when the text isn't ASCII, and a readable alternative is recommended. Replies go to the ORGANIZER address, addresses come from the iCalendar properties rather than the mail headers, and receivers should check that a message is authentic.

OAuth for installed apps:

- "Incremental authorization is not supported for installed apps or devices." `login_hint` takes an address or the `sub` value.
- Users can grant some scopes and refuse others. The granted list can name a broader scope than the one requested; the guide's example is a People API contacts scope.
- Installed apps always get a refresh token. An account keeps at most 100 refresh tokens per client, and the next one silently invalidates the oldest.
- While the consent screen's publishing status is Testing, refresh tokens expire after 7 days unless the app asks only for name, email and profile. That already applies to Tern's `gmail.modify` token.
- The ID token's `hd` claim is "provided only if the user belongs to a Google Cloud organization", which means a Workspace account.

Scope classes, from the Gmail scopes page: `mail.google.com`, `gmail.readonly`, `gmail.compose`, `gmail.insert`, `gmail.modify`, `gmail.metadata`, `gmail.settings.basic` and `gmail.settings.sharing` are restricted. A public app with restricted scopes needs Google's verification, and "If you store restricted scope data on servers (or transmit), then you must go through a security assessment." Tern keeps data on the Mac and talks to Google directly.

Not confirmed on the current pages, so checked in live testing (the plan works either way): the HTTP status of an expired People sync token (400 or 410 expected), the 403 reason for a missing scope (`insufficientPermissions` expected), what `filters.delete` returns for a missing ID, whether Gmail accepts a filter identical to an existing one and whether it rewrites criteria it stores, whether `sendAs.patch` works on an alias for an ordinary client, whether `updateVacation` clears omitted fields, the directory search error for personal accounts, Gmail's real IDLE timeout, whether IMAP can report new mail before `history.list` shows it, and the class of the contacts and directory scopes (the consent screen shows it when they're added).

## Decisions

### Settings and identities

| Area | Choice | Why |
|---|---|---|
| Scope | Reading filters, vacation and identities uses `gmail.modify`, which Tern holds. The first edit asks for `gmail.settings.basic` | The Settings panes work for every account without a new consent screen |
| Changing a filter | `replaceFilter` creates the new filter, records its ID in the queue row, then deletes the old one | Filters have no update. Deleting first would lose the filter if the create failed |
| Retried creates | Before a create's first attempt, the row stores the IDs `filters.list` returns. A retry (`attempts > 1`, the rule milestone 2's compose lane uses) lists filters again and adopts one whose criteria and actions match after normalizing (trimmed text, sorted label IDs, defaults filled in) and whose ID isn't in the stored list. A 400 on a retried create goes through the same check | A crash between Gmail's answer and the write that records it would otherwise create the filter twice, and a duplicate applies its actions twice |
| Undo | Undo of a create or replace deletes the filter that matches the created content and isn't in the row's stored ID list, looked up with `filters.list` when the undo row runs. Undo of a replace then re-creates the old content, and undo of a delete re-creates the deleted filter | Undo can run before the create's answer is stored, and the original row may be gone by then |
| Deletes | A 404 from `filters.delete` counts as done | Matches `deleteLabel`. A retried delete that already went through gets 404 |
| Forwarding filters | Shown with their forward address. Deleting one asks for confirmation and can't be undone. Editing isn't offered | Re-creating one would re-create its forward, and Tern doesn't manage forwarding addresses |
| Vacation | A row stores only the fields the user changed and their previous values. When it runs, it fetches the current settings, applies the changes and sends the whole resource in the `PUT`. Undo applies the previous values the same way | Gmail may have changed other fields since the pane opened, and the page doesn't say what omitted fields do |
| Signature editing | Offered for the primary address. Aliases show their signature read-only until live testing shows `sendAs.patch` works for them | The update page limits aliases to service accounts; the patch page is silent |
| Signature editor | Milestone 2's HTML importer loads the signature into the compose editor. A signature with formatting the importer can't keep (tables, fonts, images) stays read-only with a note to edit it in Gmail | Saving through `ComposeDocument` would drop that formatting |
| Storage | Identities live in `config.sqlite`, refreshed at launch, when Settings opens, and when compose opens with a list older than a day. Filters and vacation aren't stored: Settings fetches them when its pane opens and keeps them in memory | Compose needs identities offline and after a cache reset. Only Settings reads filters and vacation |
| Queue | Every change is a row in a new `.settings` lane: `createFilter`, `deleteFilter`, `replaceFilter`, `updateVacation`, `updateSignature`. Rows are never merged. Their claim keys are `settings:filters`, `settings:vacation` and `settings:signature:<address>`, so rows that share a key go out one at a time in the order they were made, and an undo waits behind the change it reverses | One path for every Gmail change (project rule). The queue orders rows only by shared keys, and a settings row has no thread or draft. A slow settings call shouldn't hold up archive or a send |
| Missing scope | A 403 with reason `insufficientPermissions` fails the row without retrying, and the pane offers Connect Gmail Settings | The user can revoke the scope outside Tern |

### Compose identities

| Area | Choice | Why |
|---|---|---|
| From menu | New messages list every verified address (`verificationStatus` accepted, or the primary address) of every account, grouped by account. Replies and forwards list only their conversation's account's addresses | Milestone 3 keeps a reply's account fixed |
| Default From | New messages use the account's `isDefault` address. Replies use the address the original was sent to, matched case-insensitively in its To and Cc, and otherwise the default | A reply to mail sent to an alias then comes from that alias |
| Headers | The message's From, display name and Reply-To come from the draft's identity, not from the engine's single account address | Today `ComposeQueue` writes every message from the account's own address |
| Signature | New messages get the From address's signature as a read-only block between the body and the quote, swapped when From changes. Replies and forwards get it only when the account's "Add signature to replies and forwards" setting is on, which is off by default | The API says Gmail's signature applies to new messages, not replies |
| Draft state | `localDraft` keeps the chosen From address and the signature HTML as inserted | A draft keeps its signature after the identity changes, as a sent message would |

### Contacts

| Area | Choice | Why |
|---|---|---|
| Sources | Saved contacts (`connections.list`) and other contacts (`otherContacts.list`) are synced into `cache.sqlite` with sync tokens. Directory search runs live, for Workspace accounts only | Local data works offline, answers each keystroke at once and ranks together with cached addresses |
| Search calls | `searchContacts` and `otherContacts.search` aren't used | They need a warm-up call, cap results at 30 and don't work offline. The local copy holds the same data |
| Fields | `personFields` and `readMask` are `names,emailAddresses,metadata`. They're stored with the sync token, and a change to them drops the token | `metadata` brings back deleted people as deleted. A sync token only works with the parameters that issued it |
| Paging | Full and incremental syncs both page, with `pageSize=1000` and the same parameters, `syncToken` and `requestSyncToken` included, on every page. The new token from the last page is stored only in the write that applies every page | A token saved after a partial sync would skip the missing pages for good |
| Token age | A full sync runs when the last one is 7 days old, before its tokens expire | Sync tokens expire 7 days after the full sync, whatever happens in between |
| Expired token | Stage A reports a 400 or 410 on a request that carried a token as a possible expiry. The engine treats it as one only when the last full sync is at least 7 days old, and otherwise reports the error. From B1, the error's `details[].reason` (`EXPIRED_SYNC_TOKEN`) decides | Until B1, `send` throws the body away and `GmailError` reads only `errors[].reason`. A 400 that keeps coming back must not start a full sync on every trigger |
| First-page quota | A 429 on the first page of a full sync waits a minute, then backs off. Full syncs, expiry ones included, run at most once a day per source | Google gives that page its own small quota |
| Schedule | Incremental sync at launch, when a compose window opens and the last sync is over 10 minutes old, and every 6 hours | Contacts change rarely, and compose is where they matter |
| Directory | Only for accounts whose ID token had `hd`. Queries of 2 characters or more, sent 300 ms after typing stops, `pageSize` 10, older requests cancelled. A 403 turns directory search off for that account until the next launch. Results aren't stored | Personal accounts have no directory, and the error they get isn't documented |
| Client | See "API client additions" below | |
| Ranking | Prefix matches first. Within them: addresses from cached mail by count and recency (milestone 2's order), then saved contacts by name, then other contacts. Directory results join after the local ones without moving them. One row per lowercased address, named from a saved contact, else the cached display name, else other contacts | People the user writes to most stay on top, and the list doesn't jump while the user arrows through it |
| Storage | `cache.sqlite`, deleted with the account and rebuilt after a cache reset | Google holds the data, so dropping it loses nothing |

### Inbox updates

| Area | Choice | Why |
|---|---|---|
| Signal only | A new `IMAPIdle` target connects to `imap.gmail.com:993` with Network.framework, TLS and TCP keepalive, signs in with XOAUTH2, runs `EXAMINE INBOX`, then `IDLE`. Once `EXAMINE` has finished, any `EXISTS`, `EXPUNGE` or `FETCH`, during `IDLE` or between `DONE` and the next `IDLE`, becomes an "INBOX changed" signal. Tern never fetches mail over IMAP | History sync already does the fetching. `EXAMINE` opens INBOX read-only, so IMAP can't change flags. RFC 3501 lets the server send these updates at any time in the selected state |
| Capabilities | `CAPABILITY` before signing in: without `AUTH=XOAUTH2` the stream ends as unsupported, and without `SASL-IR` the token goes after the `+` continuation instead of on the command line. After signing in, `IDLE` must be in the tagged `OK`'s capability code or in a second `CAPABILITY` answer, or the stream ends as unsupported | RFC 3501 §6.2.2, RFC 4959 and RFC 2177 |
| Structure | A response parser, a session state machine that takes bytes and returns commands and signals, and a monitor actor that owns the connection | The parser and the state machine are tested with byte fixtures and no fake server |
| IDLE restart | `DONE` and a new `IDLE` every 9 minutes. No tagged `OK` within 30 seconds of `DONE` counts as a dead connection | Google documents no timeout. RFC 2177 says under 29 minutes, and one report puts Gmail near 15 |
| Session end | After a `BYE`, a session that lasted 10 minutes or more reconnects at once. A shorter one goes through the backoff and asks for a forced token refresh, since the token it used may have been about to expire. A failed `AUTHENTICATE` retries once with a forced refresh, and a second failure ends the stream with an auth error | Gmail closes OAuth sessions about when the token expires, and AppAuth can hand out a token with a minute left. A server that answers every connection with `BYE` mustn't cause a tight loop |
| Reconnects | Backoff from 1 second, doubling to 5 minutes, with ±20% jitter, reset once a session has idled for a minute. The app also reconnects on wake and when the network comes back | Sleep and network changes drop the connection without a `BYE` |
| After a reconnect | One signal after each successful `EXAMINE` | A change made while disconnected isn't missed |
| Engine | `SyncEngine.requestSync()` coalesces requests: during a pass it runs one more pass afterward. If a pass started by a signal finds no history, it runs once more 5 seconds later | `sync()` joins a running pass, so a signal that arrives mid-pass could be lost. IMAP may report new mail before history shows it (unconfirmed) |
| Polling | The 60-second poll stays | IDLE watches INBOX only. Other changes still arrive through history |
| Privacy | Raw IMAP lines, the XOAUTH2 string, the address and the token are never logged | The XOAUTH2 string holds both the address and the token |

Faster, adaptive `history.list` polling was the alternative. It wasn't chosen (answered question 1).

### Invitations

| Area | Choice | Why |
|---|---|---|
| Reply path | An emailed iTIP REPLY through milestone 2's compose lane, as a local draft of kind `invitationReply` with the usual undo send notice | Works with any organizer's calendar system and needs no new scope |
| Calendar API | Not used. The alternative, recorded as open question 1, is `calendar.events.owned`: `events.list` by `iCalUID`, then `events.patch` of the attendee list with `sendUpdates=all` | It would update the user's own Google Calendar copy, at the cost of another scope and a patch that replaces the whole attendee list |
| Buttons | Accept, Maybe and Decline appear for METHOD:REQUEST when an ATTENDEE matches one of the account's addresses. A CANCEL shows the event as canceled. A REPLY, where the user is the organizer, shows who answered what | Under RFC 5546 only invited attendees reply |
| Which version | Per account, UID and RECURRENCE-ID, the newest version is the one with the highest SEQUENCE, then the latest DTSTAMP, across every cached message in the account. A banner on an older copy says a newer version exists and shows no buttons | Updates and cancellations often arrive in a new thread with a new subject. RFC 5546's ordering rule |
| Authenticity | When the From address doesn't match ORGANIZER, the banner says so. The buttons show where the reply goes | RFC 6047 asks receivers to check. A reply to a forged organizer tells the sender the address is read |
| Time zones | TZID first as an IANA name, then the object's VTIMEZONE, otherwise the time as written with the zone's name and no conversion. In a VTIMEZONE, the rule that applies is the STANDARD or DAYLIGHT block with the latest onset before the event; onsets come from each block's DTSTART read at its TZOFFSETFROM and its yearly `BYMONTH` and `BYDAY` rule. DATE values are all-day, and the banner shows an exclusive DTEND as the day before. DURATION applies when DTEND is missing; with neither, a date-time event ends at its start and a date event after one day | Outlook sends Windows zone names with a VTIMEZONE. These are RFC 5545's rules |
| Reply content | VCALENDAR with VERSION:2.0, PRODID and METHOD:REPLY. One VEVENT with UID, SEQUENCE, DTSTAMP now in UTC, ORGANIZER copied, SUMMARY, and one ATTENDEE whose value is copied exactly as the request wrote it, with the chosen PARTSTAT, its CN, and no RSVP parameter. RECURRENCE-ID, when the request had one, is copied as written together with the request's VTIMEZONE for its TZID; without such a VTIMEZONE, a TZID value goes out converted to UTC. No DTSTART, DTEND or VALARM. The message is `multipart/alternative` with a short plain text line ("Accepted: <summary>") and `text/calendar; method=REPLY; charset=UTF-8` | RFC 5545 requires VERSION, PRODID and a VTIMEZONE for every TZID used. Organizers match the attendee by its exact value. RFC 5546's REPLY doesn't require the time properties |
| Size cap | Calendar data over 1 MB isn't parsed, and a calendar part whose size Gmail reports above 1 MB isn't downloaded | A crafted invitation can't stall the thread view |

### Feature authorization

| Area | Choice | Why |
|---|---|---|
| Features | Each account has a set of enabled features: Gmail Settings (`gmail.settings.basic`), Contacts (`contacts.readonly` and `contacts.other.readonly`, plus `directory.readonly` for Workspace accounts) and Inbox Updates (`https://mail.google.com/`) | Each consent screen asks only for what the user turned on |
| Turning one on | A new authorization for the base scopes, the scopes of features already on and the new ones, with `login_hint` set to the account's `sub`. Tern checks that the ID token's `sub` matches the account, that `gmail.modify` is still granted, and that the granted list covers each new scope, where a broader granted scope counts | Installed apps can't add scopes incrementally. A different account picked in the browser must not replace this one, and the consent screen lets the user untick `gmail.modify` |
| Rejected grants | A different `sub` or a missing `gmail.modify` throws the new grant away and keeps the old Keychain item and session. A missing feature scope keeps the new grant, leaves the feature off and names the missing permission in Settings | Tern must never lose mail access while adding a feature |
| Switching over | The account's session swaps its live authorization state, then writes the Keychain item, then `grantedScopes` in `config.sqlite`. At launch, `grantedScopes` is corrected from the Keychain state's scope if the two differ. A token request that loses the race with the swap retries once with the new state instead of reporting an expired session | The running engine would otherwise keep the old token until relaunch and hit 403. The Keychain and the database can't change in one transaction |
| Turning one off | Tern stops using the scope and drops the feature's local data. The grant stays until the user removes Tern on their Google Account's permissions page, which removes all of Tern's access. Settings says so | Shrinking a grant would mean revoking it |
| Old tokens | The previous refresh token is dropped, not revoked | A revoke could end the whole grant, the new token included. A few re-authorizations come nowhere near the limit of 100 tokens |
| Hosted domain | Sign-in stores the ID token's `hd` claim as `account.hostedDomain`. Accounts added earlier get it from the ID token in their stored authorization at launch, or at their next authorization | Decides whether the directory scope is requested |

### Migrations

| Area | Choice | Why |
|---|---|---|
| Names | Config: `integrations-v1`. Cache: `settings-v1`, `contacts-v1`, `invitations-v1`, `identity-v1`. All registered after milestone 3's migrations | GRDB tracks migrations by name, and no other branch uses these |

## Scopes per feature

| Feature | Reading | Changing | Scope class |
|---|---|---|---|
| Filters and vacation | `gmail.modify` (held) | `gmail.settings.basic` | Restricted |
| Identities, From menu, signatures | `gmail.modify` | `gmail.settings.basic`, for signature edits only | Restricted |
| Contact suggestions | `contacts.readonly`, `contacts.other.readonly`; `directory.readonly` for Workspace accounts | Nothing | Sensitive expected; the consent screen settles it |
| Invitations | `gmail.modify` (message bodies) | `gmail.modify` (`drafts.send`) | No new scope |
| Inbox updates | `https://mail.google.com/` | Nothing | Restricted, the broadest Gmail scope |

## Data model

`config.sqlite`, `integrations-v1`:

- `account` gains `hostedDomain` (null for personal accounts and while unknown), `enabledFeatures` (a JSON array, empty by default) and `signatureOnReplies` (false by default).
- `sendAsIdentity`: account (foreign key, cascading), address as Gmail returns it, lowercased address, display name, Reply-To, signature HTML, primary, default, treat as alias, verification status, fetched at. Primary key (account, lowercased address).

`cache.sqlite`:

- `settings-v1`: `pendingAction` gains `settingsChange`, a JSON value with each kind's payload: for a create, the new filter and the filter IDs listed before the first attempt; for a delete, the filter's ID and content; for a replace, the old ID and content, the new filter, the IDs listed before the first attempt and, once known, the new ID; for vacation, the changed fields with their new and previous values; for a signature, the address and the new and previous HTML.
- `contacts-v1`:
  - `contact`: account, source (`connection` or `other`), resource name, display name, updated at. Primary key (account, source, resource name).
  - `contactEmail`: account, source, resource name, lowercased address, address as written, primary. Foreign key to `contact`, cascading. Index on (account, lowercased address).
  - `contactSync`: account, source, sync token, the fields the token was issued for, last full sync. Primary key (account, source).
- `invitations-v1`:
  - `messageCalendar`: account, message ID, UID, RECURRENCE-ID (not null; empty for the whole event, otherwise in UTC when it can be resolved), SEQUENCE, DTSTAMP, method, and the parsed invitation as JSON. Primary key (account, message ID), foreign key to `message`, cascading. Index on (account, UID, RECURRENCE-ID).
  - `invitationReply`: account, UID, RECURRENCE-ID (not null, keyed the same way), PARTSTAT, local draft ID, queued at. Primary key (account, UID, RECURRENCE-ID). The banner shows the answer already given. SQLite treats NULLs in a primary key as distinct, so an empty string stands for the whole event.
- `identity-v1`: `localDraft` gains `fromAddress`, `signatureHTML` and `calendarPart`, and its kind gains `invitationReply`.

`deleteAccountData` adds the contact tables, `messageCalendar` and `invitationReply`. Identities go with the account through the config foreign key.

## API client additions

- Settings calls go through `Endpoint`. Its memberwise initializer covers the `PUT` for vacation.
- `sendAs` paths carry an address, which `Endpoint.components()` would leave with a bare `+` or encode twice. Those calls take `Endpoint.components()`, set `percentEncodedPath` with the address percent-encoded once (`a+b@example.com` becomes `a%2Bb%40example.com`), and pass the `URLRequest` to the internal `send(_:forceRefresh:)`.
- `PeopleClient` is a struct in `GmailAPI` that wraps a `GmailClient` built from the same token provider and transport, since `GmailClient` keeps both private. It builds its own `URLRequest`s for `people.googleapis.com`, repeats `Endpoint`'s `+` to `%2B` fix for query values, and sends through the wrapped client's `send(_:forceRefresh:)`, so the bearer token and the single refresh after a 401 are the same code. A separate target couldn't reach that internal API without changing `GmailClient.swift`, and a copy of the retry code would drift. Stage B moves the shared code into `GoogleSession`.
- `GmailError` stays as it is in stage A. A missing-scope check (`.http(status: 403, reason: "insufficientPermissions")`) is an extension in a new file.

## Flows

### Changing a filter

1. The Filters pane lists `filters.list`, with label IDs shown as label names.
2. Saving an edited filter queues `replaceFilter` with the old ID and content and the new content. The pane shows the new content at once, marked as saving.
3. The row's first attempt lists filters and stores their IDs in the payload, calls `filters.create` and writes the new ID into the payload. It then calls `filters.delete` on the old ID, where a 404 counts as done.
4. A later attempt without a new ID in its payload first looks for a matching filter outside the stored IDs, as described under "Retried creates".
5. Undo queues a reverse row with the same claim key, so it runs after the change: it finds the created filter by content, deletes it, and re-creates the old one.
6. A 400 from a first create (Gmail rejected the criteria) fails the row. The pane restores the old filter and shows Gmail's message.

### Vacation

The pane fetches the vacation settings when it opens. Save checks that the start comes before the end and that an enabled reply has a subject or a body, then queues `updateVacation` with the changed fields. The row fetches the current settings, applies its fields, checks the same rules again and sends the `PUT`. The response replaces the pane's copy.

### Identities and signatures

A refresh calls `sendAs.list` and replaces the account's identity rows in one config write. A signature edit queues `updateSignature`, which patches only `signature`, and the identity row takes the response. Compose reads identities from `config.sqlite` only.

### Contacts sync

1. With no usable sync token for a source (none stored, fields changed, or the last full sync 7 days old), a full sync pages through the list, holds the pages in memory, and writes them in one transaction that replaces the source's rows and stores the new token.
2. With a token, an incremental sync pages the same way and applies changed and deleted people and the new token in one write.
3. An expired token goes back to step 1, within the once-a-day limit.
4. Every write goes through the engine's `write` gate, so nothing lands after sign-out stops the engine.

### Inbox updates

1. Turning on Inbox Updates for an account authorizes `https://mail.google.com/` as above.
2. The app starts an `InboxWatcher` for each account with the feature. It owns an `InboxMonitor` that takes the account's address and its `AccountSession` as the token provider.
3. Each signal calls `requestSync()` on the account's engine.
4. A permanent auth failure or an unsupported server stops the watcher. Settings shows "Inbox updates paused" with a Reconnect button, and the 60-second poll carries on.
5. Sign-out stops the watcher before the engine.

### Invitations

1. When a body is stored, the calendar part is found: a `text/calendar` part outside attachments first, then an attached `.ics` or `application/ics` file with a METHOD. `requiredAttachmentIDs` includes it when Gmail returns it by attachment ID and reports 1 MB or less. The parsed invitation goes into `messageCalendar` in the same transaction as the body.
2. The thread view reads the thread's `messageCalendar` rows, looks up the newest version of each UID and RECURRENCE-ID across the account, and shows the banner.
3. Accept, Maybe or Decline creates a local draft of kind `invitationReply` addressed to the ORGANIZER, from the identity that matched the ATTENDEE, with the subject "Accepted: <summary>" (or "Tentatively accepted" or "Declined"), and queues it for sending with the undo send delay. The `invitationReply` row is written in the same transaction. No compose window opens.
4. Undo send removes the draft and the `invitationReply` row. Changing the answer later sends a new reply with a new DTSTAMP.

## UI

- Settings:
  - The Accounts pane from milestone 3 gains a Connections list per account: Gmail Settings, Contacts and Inbox Updates. Each has a switch and a status line.
  - Signatures: each account's addresses, a sanitized preview of each signature, Edit for the primary address, and the "Add signature to replies and forwards" switch.
  - Filters: each filter's criteria and actions in one line, Add, an editor sheet, and Delete with undo. Forwarding filters are read-only, and deleting one asks first. Add is disabled at 1,000 filters.
  - Vacation: the switch, first and last day, subject, message (plain text; an HTML message the importer can't keep is read-only with a note), "Only send to people in my contacts", and for Workspace accounts "Only send to people in <domain>".
  - Without `gmail.settings.basic`, edit controls are disabled and the pane says "Connect Gmail Settings to make changes", with a button that starts the authorization.
  - With more than one account, each pane has an account picker.
- Compose: a From menu, the read-only signature block, and suggestions that show the name and address.
- Thread view: the invitation banner above the first message, with the title, date and time in the local time zone (and the event's own zone when it differs), location, organizer, a "Repeats" note, the user's answer, and the buttons. Canceled events and outdated copies have their own style. The organizer warning sits inside the banner.
- VoiceOver labels on every new control, and an announcement when an answer is queued. Spacing and radii come from `App/Design/Tokens.swift`.

## Phases

The user approves this plan before stage A starts. Each phase touches at most five files, counting tests but not the regenerated `Tern.xcodeproj` or `Package.resolved`, and builds on its own. Each ends with its checks passing and gets its own commit. A phase that turns out to need a sixth file splits, and the handoff records the split.

Checks: "App" is the Debug build (`xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build build`), then `swift test --package-path Packages/Core` last, so `Package.resolved` is left as `swift test` leaves it. "Launch" adds a run of the Debug build and a look at the feature, with screenshots. "Full" is `xcodegen generate`, the Debug build, `TernTests` and `swift test`.

### Stage A: new files, now

| # | Phase | Files | Check |
|---|---|---|---|
| A1 | `GmailAPI` settings: filter, vacation and send-as models and calls, the missing-scope check, and test stubs other test files can share | `GmailSettings.swift`, `GmailClient+Settings.swift`, `TestSupport.swift`, `GmailSettingsTests.swift` (all new) | App |
| A2 | `GmailAPI` People client: saved and other contacts with paging and sync tokens, directory search, person models | `PeopleClient.swift`, `PeopleModels.swift`, `PeopleClientTests.swift` (all new) | App |
| A3 | `MessageContent` invitations: iCalendar reader and writer, time zones, the invitation model and the payload part finder, the REPLY builder | `ICalendar.swift`, `ICalendarTimeZone.swift`, `Invitation.swift`, `InvitationReply.swift`, `InvitationTests.swift` (all new) | App |
| A4a | The `IMAPIdle` target and its response parser | `Package.swift`; `IMAPResponseParser.swift`, `IMAPResponseParserTests.swift` (new) | App |
| A4b | XOAUTH2, the session state machine, backoff and the monitor actor | `IdleSession.swift`, `InboxMonitor.swift`, `IdleSessionTests.swift` (all new) | App |

A2 uses A1's test stubs, so it follows A1. A3 and A4 depend on neither. Stage A ends with `SESSION_HANDOFF.md`.

Until B1, the new `GmailAPI` test files use their own stubs (`RecordingTransport`, `CountingTokens`), since the ones in `GmailAPITests.swift` are private and stage A leaves that file alone. The A3 part finder has its own attachment check, since `MIMEParts.isAttachment` is private; B6a replaces it with the shared one.

### Stage B: wiring, after milestones 2 and 3

| # | Phase | Files | Check |
|---|---|---|---|
| Gate C | You confirm milestones 2 and 3 are done. With your approval, `refs/heads/feat/milestone-3` is merged, and `refs/heads/feat/milestone-2` too if it has moved past what milestone 3 merged. Then cleanup commits (workspace rule 9) for the files over 300 lines that stage B changes, listed at the gate | | Full |
| B1 | `GoogleSession`: the bearer token, the 401 refresh, the transport and JSON coding move out of `GmailClient`; errors keep `details[].reason`; both clients use it; one set of test stubs | `GmailClient.swift`, `PeopleClient.swift`, `GmailAPITests.swift`, `TestSupport.swift`; `GoogleSession.swift` (new) | App |
| B2 | Store: the five migrations, the new records and the `settingsChange` column, contact, identity and invitation queries, account deletion. No new action kind yet | `Schema.swift`, `Records.swift`, `MailCache.swift`; `IntegrationStore.swift`, a test file (new) | App |
| B3 | Feature authorization: feature scopes and the granted-scope check (pure, in `GmailAPI`), re-authorization with `login_hint`, the `sub` and `gmail.modify` checks, the live swap, `hd` | `GoogleAuth.swift`, `AccountSession.swift`, `AppModel.swift`; `GoogleScopes.swift`, a test file (new) | Launch |
| B4a | Settings kinds: the five kinds and the `.settings` lane, their claim keys, and the cases the exhaustive switches need. No settings row is queued yet | `Records.swift`, `MailCache.swift`, `ActionQueue.swift`, `ComposeQueue.swift`; a test file (new) | App |
| B4b | Settings delivery: a `SettingsService` protocol that `GmailClient` adopts, delivery, the ID list and adoption on retries, vacation merging, undo, a fake in the new test file. `GmailService` and the existing fakes stay as they are | `SyncEngine.swift`, `AppModel.swift`; `SettingsQueue.swift`, `SettingsQueueTests.swift` (new) | App |
| B5 | Identity refresh, contact sync behind a `PeopleService` protocol, `requestSync()` and the retry after an empty signalled pass | `SyncEngine.swift`, `AppModel.swift`; `IdentitySync.swift`, `ContactSync.swift`, a test file (new) | App |
| B6a | Calendar parts: `isAttachment` becomes internal and the A3 finder uses it, `requiredAttachmentIDs` includes calendar parts within the cap, stored bodies write `messageCalendar` | `MIMEParts.swift`, `Invitation.swift`, `MailCache.swift`, a test file | App |
| B6b | Outgoing identity: From, display name and Reply-To from the draft, the signature block, the calendar part, `invitationReply` drafts | `MIMEWriter.swift`, `ComposeQueue.swift`, a test file | App |
| B7 | Inbox updates in the app: `InboxWatcher`, the `IMAPIdle` product, wake and network hooks | `Package.swift`, `project.yml`, `AppModel.swift`; `InboxWatcher.swift` (new) | Launch |
| B8 | Compose: the From menu, the signature block, the reply default, suggestions merged with contacts and the directory | `ComposeModel.swift`, `ComposeView.swift`, `RecipientField.swift`, `Queries.swift`, a test file | Launch |
| B9 | The invitation banner, with the newest version across the account | `ThreadView.swift`, `Queries.swift`; `InvitationBanner.swift`, `InvitationModel.swift` (new) | Launch |
| B10a | Settings: Connections in the Accounts pane and the Signatures pane | `SettingsView.swift`; `SettingsModel.swift`, `ConnectionsView.swift`, `SignaturesPane.swift` (new) | Launch |
| B10b | Settings: the Filters and Vacation panes | `SettingsView.swift`, `SettingsModel.swift`; `FiltersPane.swift`, `FilterEditorSheet.swift`, `VacationPane.swift` (new) | Launch |
| B11 | Review pass and fixes | As found | Full |

The file lists in stage B follow milestone 3's plan and get checked against the merged code at Gate C. New engine calls sit behind their own protocols so `SyncEngineTests.swift` (over 1,100 lines) doesn't need to change.

## Tests

Tests target failures that would lose or duplicate a filter, overwrite a setting, send a wrong RSVP, show the wrong time, leak a token or miss new mail. Each test file has its own fixtures, written inline with example.com addresses.

Stage A:

- Settings:
  - `filters.list` with no filters, where Gmail leaves out `filter`, returns an empty list rather than a decoding error.
  - A new filter's body has no `id` and leaves unset criteria out. An unknown `sizeComparison` from Gmail doesn't fail the list.
  - `deleteFilter` treats 404 as done.
  - Vacation times: epoch-millisecond strings decode to dates and encode back as strings. An update with the start after the end, or enabled with neither subject nor body, throws before any request. The update is a `PUT` with every field.
  - `sendAs.list` decodes verification status and flags. `updateSignature` sends `{"signature": …}` and nothing else. An address with `+` reaches the path as `%2B`, encoded once.
  - A 403 with reason `insufficientPermissions` reads as a missing scope.
- People:
  - A full sync over two pages sends the same parameters on both, adds the page token on the second, and returns the sync token from the last page.
  - An incremental sync over two pages sends `syncToken` and `requestSyncToken` on both, deleted people come back marked as deleted, and the token comes from the last page.
  - A 400 or 410 on a request with a sync token reports a possible expiry. The same status without one throws.
  - Directory search sends both sources and encodes `+` in the query. A 403 reports the directory as unavailable.
  - Requests go to `people.googleapis.com`, and a 401 gets one forced token refresh, which shows the shared send path is in use.
  - The primary name wins over others, and people without addresses yield no entries.
- Invitations:
  - Unfolding with a space and with a tab, including a fold that splits a multi-byte UTF-8 character.
  - TEXT escapes, and quoted parameter values that contain `:`, `;` and `,`.
  - METHOD REQUEST, CANCEL, REPLY and an unknown method.
  - DTSTART in UTC, with an IANA TZID, floating, and as an all-day DATE whose exclusive DTEND shows as the day before. A missing DTEND with DURATION, and with neither.
  - A Windows TZID with a VTIMEZONE, on both sides of a daylight saving change, where the rule onset is read at its TZOFFSETFROM; and a VTIMEZONE with several STANDARD and DAYLIGHT blocks, where the latest onset before the event wins.
  - ATTENDEE PARTSTAT, and matching `mailto:` addresses to the account's addresses regardless of case.
  - A master VEVENT with an override instance picks the master.
  - Malformed input: no VEVENT, no UID, an unclosed BEGIN, junk lines, input over the size cap, and a Latin-1 part decoded with its declared charset.
  - The payload part finder picks the `text/calendar` alternative over an attached `.ics`.
  - The REPLY has VERSION:2.0, PRODID and METHOD:REPLY, one ATTENDEE whose value matches the request's exactly, with the chosen PARTSTAT and no RSVP, the request's UID and SEQUENCE, the ORGANIZER and no VALARM. A RECURRENCE-ID with a TZID comes with the request's VTIMEZONE, or in UTC when the request had none. Lines end in CRLF, none is over 75 octets, and the REPLY parses back to the same values.
- IMAP:
  - Parser: a response fed one byte at a time parses the same as in one chunk. A literal is skipped by its byte count, CRLF inside it included. Tagged `OK`, `NO` and `BAD` with response codes, `+` continuations, `EXISTS`, `EXPUNGE`, `FETCH` and `BYE`. A line or literal over the cap is a protocol error.
  - Session: the commands from greeting to `IDLE`; the XOAUTH2 line for a known address and token, on the command line with `SASL-IR` and after the continuation without it; no `AUTH=XOAUTH2` or no `IDLE` ends the stream as unsupported; a challenge after `AUTHENTICATE` gets an empty line, then one retry with a forced refresh, then a permanent failure; `EXISTS`, `EXPUNGE` and `FETCH` signal during `IDLE` and between `DONE` and the next `IDLE`, and other untagged lines don't; the 9-minute timer sends `DONE` and a new `IDLE` with a new tag; no `OK` within 30 seconds of `DONE` closes for a reconnect; a `BYE` after a long session reconnects at once and after a short one goes through the backoff with a forced refresh; one signal follows a successful `EXAMINE`.
  - Backoff: doubling, the cap, the jitter range, and the reset after a steady session.
  - The `NWConnection` wiring isn't unit tested. Live testing covers it.

Stage B:

- Settings queue: two vacation rows go out in order even when the first waits on a retry; an undo waits behind its change; a replace creates before it deletes, and a crash between the two leaves the new ID recorded; a retried create adopts the match outside the stored IDs instead of creating a second filter, and a 400 on a retry goes through the same check; an undo that runs before the create's answer was stored still deletes the created filter; a vacation change made in Gmail after the pane opened survives a Tern edit to another field; settings rows don't wait behind a compose upload; a missing-scope 403 fails the row without retrying.
- Feature authorization: a different `sub` or a grant without `gmail.modify` is rejected and the old session kept; a partial grant leaves the feature off; a broader granted scope counts; after the swap, the next token request uses the new grant.
- Contacts: the sync token is stored only with the write that applies every page; changed fields drop the token; a 400 with a token counts as expiry only after 7 days; full syncs stay within one a day; deleted people disappear; deleting the account clears contact rows; a cached address the user writes to ranks above a saved contact with the same prefix; an address in both appears once with the contact's name; directory results don't reorder local ones.
- `requestSync()`: one or several requests during a pass cause exactly one more pass, and an empty signalled pass runs once more after 5 seconds.
- Compose identities: a reply's From is the alias the original went to; the message's From, display name and Reply-To come from the identity; changing From swaps the signature; the signature sits between body and quote in both HTML and plain text; replies have no signature unless the setting is on.
- Invitations: the calendar part is found as inline data, by attachment ID, and as an attached `.ics`, and one over the cap isn't downloaded; the newest version wins across threads and older copies show no buttons; answering the whole event twice leaves one `invitationReply` row; a reply draft goes to the organizer with the right MIME parts; undo send removes the `invitationReply` row.

No UI snapshot tests.

## What you need to do

- In the Google Cloud project that holds the OAuth client from milestone 1:
  - Enable the People API. The Calendar API is needed only if open question 1 goes that way.
  - On the OAuth consent screen, add `gmail.settings.basic`, `contacts.readonly`, `contacts.other.readonly`, `directory.readonly` and `https://mail.google.com/`. Note the class the console shows for each.
  - Keep every account you'll test with on the test user list.
- While the consent screen stays in Testing, refresh tokens expire after 7 days, so expect to sign in again each week. This already applies today.
- For Workspace accounts, the admin must allow IMAP and directory sharing (for directory suggestions), and may need to trust the OAuth client if third-party apps are restricted.
- For personal accounts, check that Gmail's "Forwarding and POP/IMAP" settings show IMAP as enabled.
- After stage B, live testing covers the unconfirmed behaviors listed above, invitations from Google Calendar and from Outlook answered in Tern and checked on the organizer's side, and the user's own Google Calendar after a reply.

## Risks

- IMAP: Google documents no IDLE timeout, so the 9-minute restart rests on RFC 2177 and one report. Sleep, network changes and firewalls that block port 993 drop the connection, and the poll stays as the fallback. Workspace admins can turn IMAP off, and IMAP being always on for personal accounts is unconfirmed.
- The full mail scope: a leaked access token could permanently delete mail, which a `gmail.modify` token can't. Tokens stay in the Keychain and in memory.
- Public release: `gmail.settings.basic` and `mail.google.com` are restricted, like `gmail.modify`, so each needs Google's verification. Whether Google also asks for the security assessment depends on how it reads "store or transmit on servers"; Tern doesn't do either.
- A filter replace leaves two filters for a moment, so mail arriving then gets both sets of actions.
- If Gmail rewrites the criteria it stores, the content match after an unclear create can miss, and a duplicate filter is left. Normalizing before comparing covers the expected cases; live testing checks what Gmail stores.
- Emailed RSVPs: the organizer's calendar should take the reply, and live testing checks a Google Calendar and an Outlook organizer. The user's own Google Calendar copy may keep the old answer. Open question 1 covers the alternative.
- A newer version of an invitation counts only once its message body is in the cache. Until then, an older copy can still show buttons, and an answer goes out for the version shown.
- Signatures with rich formatting can't be edited in Tern.
- Accounts added before milestone 4 have no stored `hd`. If their stored authorization has no ID token either, the first Contacts authorization can't include the directory scope, and a second consent screen adds it.
- Merging with milestones 2 and 3: stage A adds files only, and Gate C handles the rest. `Tern.xcodeproj` conflicts are resolved by regenerating it.
- Until B1, `GmailAPITests` has two sets of stubs.
- Contact names and addresses sit on disk in the sandbox container, as mail does. They're never logged.
- Changes to contacts take minutes to reach the People API, so a contact added in Google Contacts may not be suggested right away.

## Answered questions

Answered on 2026-10-29:

1. Inbox updates use IMAP IDLE behind `https://mail.google.com/`, asked for only when the user turns on Inbox Updates for an account. Stage A builds A4a and A4b. Adaptive polling isn't built.
2. The stage A phases run back to back, each tested and committed.

## Open questions

These follow the plan unless you say otherwise:

1. Invitation replies. Planned: emailed iTIP replies, with no new scope. The alternative is the Calendar API with `calendar.events.owned`, which also updates your own Google Calendar copy.
2. Signatures on replies and forwards. Planned: off by default, with a per-account switch.
