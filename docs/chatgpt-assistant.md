# ChatGPT assistant

Tern uses Sign in with ChatGPT to connect its assistant to your ChatGPT plan. Model choices come from the connected account. No OpenAI API key or Codex installation is needed.

## Connect

1. Open Tern, then **Settings → Assistant** or the floating **Assistant** button and its settings.
2. Choose **Continue with ChatGPT** and finish signing in in your browser. Grant ChatGPT plan usage when offered. An identity-only connection cannot run the assistant.
3. Enable the mail accounts the assistant may use and choose an available model.
4. Select a conversation, open the assistant, and ask a question. Change the scope to use the current account or all enabled accounts when needed.

Try “Summarize this thread and list the unfinished tasks,” “What needs my attention this week?” or “Draft a reply confirming Friday.” Open a source to read the supporting conversation. **Open draft** opens the normal Tern composer for editing and sending.

The assistant can search mail, read threads, extract supported attachments, and prepare drafts. Search results are paginated and subject to request limits; a single request does not read an entire mailbox. The initial attachment reader supports plain text, CSV, Markdown, JSON, XML, and PDFs with selectable text. Files are limited to 5 MB; extraction is limited to 60,000 characters and 40 PDF pages. Scans need OCR, which is not included.

## Chat controls and data

The floating panel, separate window, and full-screen view share one conversation. **Stop** cancels the current request. A draft already created remains in Drafts. **New chat** clears the conversation. Chat history stays in memory and is discarded when Tern quits.

Mail access starts disabled. Relevant content from enabled accounts is sent to OpenAI when needed for your requests. Changing the effective scope or removing access clears retained conversation content and cancels active work. Reading mail through the assistant does not mark it read. Sending remains an action in the compose window.

Tern stores its own ChatGPT connection in macOS Keychain, separate from Gmail and other apps. **Disconnect** clears local authorization and requests remote revocation. If revocation fails, Tern reports it; local use remains disabled. **Manage usage** opens ChatGPT's usage controls.

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

See the [implementation plan](plans/chatgpt-integration.md) for verification targets and the [feature roadmap](plans/ai-and-features-roadmap.md) for later product features.
