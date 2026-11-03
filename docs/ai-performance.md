# AI workflow performance

The November 2026 performance pass covers all six inference workflows. It removes repeated work and overlaps independent preparation while preserving the selected models, source coverage and result validation.

| Workflow | Change |
| --- | --- |
| Chat | Reuses network connections, consumes response chunks and batches text display updates. Searches up to three permitted accounts concurrently, then registers results in account order. |
| Compose | Uses the same transport and text updates. Prepares writing style while reading the current conversation. |
| Automatic thread summaries | Readers requesting the same source, scope and model share one mail read and generation. Completed results retain the existing session cache; request IDs prevent older results from replacing a newer refresh. |
| Email event interpretation | Readers share identical pending inference. Keys include account ownership, thread, scope, access revision, model, source content, extraction rules and time zone. Independent local metadata reads overlap message preparation. |
| Writing-style learning | Reads 100 selected messages in five batches of 20 instead of ten batches of 10, within the existing Gmail client's limit of 25. Source ordering and body/excerpt budgets remain intact. |
| Mail organization | Computes canonical label matches once per sampled message and reuses them across request-size attempts, preserving the ranked label context. |

All workflows use the pooled ephemeral AI session. Cookies, cache and credential storage are disabled, redirects are refused, and canceling one response affects only its own network task. Queued response data remains bounded to 2 MiB.

Chat and compose publish their first text fragment immediately. Later fragments share a 40 ms trailing display update; completion publishes the authoritative reply synchronously. Stop and interruption retain received partial text. Access changes suppress delayed publication.

Shared pending requests give each reader its own cancellation lifetime. Canceling one reader leaves other readers running; canceling the final reader cancels the worker. Scope and model changes cancel invalid work. Refresh bypasses the completed summary cache but joins identical work already running under the same access revision. Each summary reader still validates its expected messages before using the result.

JSON encoding uses stable object-key order and leaves slashes unescaped. This preserves decoded content, removes redundant escaping in embedded JSON and gives reconstructed prompt data a stable representation. A provider prompt-cache benefit has not been measured.

## Measurements and verification

The local transport benchmark consumed identical 139,776-byte responses in median 6.853 ms before the change and 0.375 ms afterward. Across 21 loopback HTTP requests, the earlier implementation opened 21 connections; the pooled implementation used one. These measurements exclude internet/TLS latency, model generation, SSE parsing and rendering.

An optimized synthetic encoding benchmark used 100 messages and 100 measured iterations. Payload size fell from 129,171 to 119,171 bytes; median encoding time was 0.711 ms before and 0.608 ms afterward. The slash-heavy fixture demonstrates the effect of redundant escaping; ordinary messages will differ.

Synthetic provider tests cover request sharing, cancellation isolation, access revocation, source changes, refresh ordering, streamed tails, account-search ordering and sample budgets. Verification runs use synthetic mail and provider responses. No live-provider latency improvement or model-quality change is claimed.

Local build logs, test results, source hashes and raw benchmark inputs/results are retained under `build/Verification/ai-workflows/` and `build/Verification/ai-response-speed/`. Changes to the installed app require a separate build and installation.
