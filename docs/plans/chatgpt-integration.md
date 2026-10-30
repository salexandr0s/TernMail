# ChatGPT integration

Date: 2026-10-30. Completed implementation: Tern's reusable AI integration using ChatGPT/Codex.

## Scope and connection

Use the official Sign in with ChatGPT flow for local applications. Register Tern during browser sign-in, retain its own issued client ID and stable installation host ID, verify identity, and store credentials in a separate Keychain service. Fetch the signed-in account's model catalogue and call the public Responses API using its ChatGPT plan permission. This supplies the inference service for Tern's assistant and future features.

Gatekeeper provides the protocol and lifecycle reference. The official devkit and current documentation take precedence where their contracts differ. Use direct HTTP/SSE in this native sandboxed app; a Codex CLI process, API key, or remotely hosted MCP plugin is not required for this connection.

References:

- [Sign in with ChatGPT devkit](https://github.com/openai/sign-in-with-chatgpt-devkit)
- [Integration cookbook](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt)
- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limits](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)

## Implementation stages

1. Add a Core AI module: Codable values, OAuth/OIDC validation, refresh and revoke operations, model discovery, bounded SSE decoding, Responses streaming, and namespaced function tools. Preserve the public API's required stateless conversation history. Add focused protocol and failure tests.
2. Add read-only mail retrieval in SyncEngine and an app tool adapter. Search all authorized accounts, fetch uncached threads without marking them read, extract text/PDF attachments, validate sources, and create editable drafts through existing queues. Derive account and attachment records from app state rather than model-supplied objects.
3. Add the native connection manager: loopback browser callback bound to 127.0.0.1, state/nonce/PKCE, Keychain persistence, serialized refresh, cancellation, disconnect and recovery. Add only the network-server entitlement needed for the temporary loopback callback; retain App Sandbox.
4. Add the shared assistant coordinator and native UI. Provide selected-thread and account scopes, explicit per-account AI access, streamed chat, source navigation, draft opening, stop/new-chat controls, model selection, and connection settings. Support a bottom-right entry point, expanded chat, and a detached window using one conversation model. Expose structured summaries through the same service for later reader/task features.
5. Verify controlled provider flows and synthetic mailbox journeys, run affected Core and hosted app tests, build Debug and Release, and inspect the native UI. Complete a live sign-in/inference check when the user's browser authorization is available. Record any live-service limitation separately from tested behavior.

Implementation ownership is split across the new Core provider/auth module, mail retrieval/tools, and app connection/UI. The lead owns manifests, existing-file integration, documentation, and final review. Preserve the concurrent design-pass changes in the canonical checkout.

## Behavior and boundaries

- Request ChatGPT plan permission explicitly through the official scopes and show connection eligibility and model errors clearly.
- Use `store: false`, `stream: true`, array input, and namespaced function tools. Do not use unsupported preview parameters or private ChatGPT endpoints.
- Keep received mail and attachments as untrusted source data. Tools enforce account permission and explicit targets before execution and recheck after suspension.
- Expose only bounded mail search/read, attachment reading, and draft preparation to the initial assistant. Sending remains in the existing compose flow.
- Preserve source references and report incomplete retrieval, truncated files, and partial scans. A search is not an exhaustive mailbox read.
- Stop active work when access changes. Clear retained conversation inputs, retrieved mail, attachment text, citations, and tool results when account access or scope changes, so the next request cannot resend excluded data. Keep ordinary mail usable without AI and discard stale assistant results after a connection or account change.
- Conversation history starts local to the running app, with an explicit clear action. Credentials and installation registration survive relaunch; generated mail content is not logged.

## Verification targets

- OAuth callback validation, ID-token signatures/claims, refresh rotation and reconnect identity.
- SSE chunk boundaries, terminal errors and truncated streams; current-account model selection and namespaced tool encoding.
- Reading an uncached thread preserves unread state; tools cannot access another account's same-named IDs.
- Attachment size/format limits and extraction errors remain visible.
- Draft creation retains reply threading, is editable, is not sent, and does not duplicate on repeated tool calls.
- Cancellation and access removal prevent late results, subsequent actions, and reuse of excluded data in conversation history.
- Chat, settings, citation navigation and draft opening work with the synthetic audit mailbox.

The remaining feature roadmap stays in [Tern feature roadmap](ai-and-features-roadmap.md). This goal delivers the shared integration and assistant; the attachment library, Today view, subscription management, and other later product surfaces remain separate features.

## Completion evidence

The final Core suite passed 281 tests in 43 suites, and the hosted app suite passed 79 tests in 17 suites. Debug and universal Release builds passed; the Release binary contains arm64 and x86_64. Logs are `/tmp/tern-ai-core-tests.log`, `/tmp/tern-ai-app-tests.log`, and `/tmp/tern-ai-release-build.log`.

Live ChatGPT authorization, model discovery, thread reads, attachment reading, sourced answers, and editable reply creation succeeded against synthetic mail. Source links selected the correct account/thread; the composer showed the requested recipient, subject, and body. Compact, popout, and fullscreen presentations were inspected. Real Gmail round trips and older macOS releases were not exercised in this verification.

Live checks found and fixed the large model catalogue and the stream's empty final output array. Completed output items are retained until response completion. Hosted tests isolate credentials and preferences, and startup loading preserves account opt-ins.
