# Mail organisation jobs

Organize Mail builds a proposed Gmail setup from the account's mail, existing labels and existing filters. The user reviews the combined plan before Apply creates labels, labels the inspected messages, and adds sender rules.

## Analysis

1. Read the current label and filter catalogues. Keep unavailable filter access distinct from an empty catalogue.
2. Read a stable window of mail, with a default limit of 5,000 messages and selectable limits of 1,000, 20,000 and 100,000. Page the listing and cache metadata in bounded chunks. Report a scan limit separately from unreadable messages.
3. Discover candidate themes in batches of 200 messages. Keep singleton candidates until the whole sample has been compared.
4. Consolidate candidate references into a shared taxonomy, comparing the complete existing catalogue in bounded partitions. Swift retains the exact message memberships; model output cannot invent mail or existing-label identities.
5. Recheck every message batch against that taxonomy. Validate sender recurrence, correspondence and conversation state across the complete sample before producing the review.

Each successful analysis stage or batch creates an in-memory checkpoint. A recoverable interruption can resume from that checkpoint while Tern remains open. Cancel and access changes discard retained work. The job continues when Settings closes.

## Review and application

Show a decision card for each suggestion: the label, its rationale, the future-mail rule choice, and optional back-tagging of matching messages in the scan. Do not show individual messages. Already covered senders and proposed additions remain available as match details. Bind existing labels to their IDs and reviewed names. Re-fetch current configuration before queueing changes. Rules-only choices retain full message evidence but do not queue message changes.

Extend an existing label's coverage through additional label-only sender filters. Preserve existing compound filters and their actions. Do not turn a forwarding, archive or deletion rule into a broader rule. Adopt exact matching filters and account for Gmail's filter limit, including queued work. Queue message labeling in chunks of at most 1,000 IDs.

The scan and every model call remain bounded. The broad scan limit is independent of the per-request batch size. Analysis still uses metadata and short previews; it does not download bodies or attachments.

## Verification

Cover cross-batch recurrence, mixed senders and newer replies; semantic consolidation and exact catalogue identities; checkpoint compatibility and resumed requests; unavailable filter context; stable paging and cancellation; stale labels; preserved existing filters; large, duplicate-safe application queues; and independent rule/back-tag decisions. Smaller mailboxes, including empty, singleton and final short batches, must complete using their actual counts. Verify loading, paused and compact review UI states with synthetic data. All Gmail writes remain in the existing action queue.

API contracts: [message listing](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list), [message label batches](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/batchModify), and [filter creation](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.settings.filters/create).
