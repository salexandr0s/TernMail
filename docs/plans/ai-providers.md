# AI provider connections

Tern's assistant supports four connection choices: ChatGPT sign-in, OpenAI API, Claude API, and DeepSeek API. The selected connection supplies every AI feature. API connections use the user's key and retain a model choice separately from ChatGPT.

## Scope and authentication

Preserve Tern's existing ChatGPT registration, OAuth verification, token rotation, revocation, and Keychain record. Add API-key connections for OpenAI, Anthropic, and DeepSeek without using credentials belonging to another application.

Public provider documentation was reviewed on November 3, 2026:

| Provider | Supported connection in Tern | OAuth finding |
|---|---|---|
| OpenAI | ChatGPT OAuth or an OpenAI API key | Retain the existing Sign in with ChatGPT implementation and its plan-access checks. |
| Anthropic | API key | Developer guidance directs applications for others to API keys or cloud providers. No public native-app subscription OAuth registration contract suitable for Tern was found. |
| DeepSeek | API key | Public API documentation describes bearer API keys; no public third-party OAuth registration/token-exchange contract for inference was found. |

Anthropic's App Attest issues device tokens billed to the registered application's workspace. Workload Identity Federation exchanges an identity-provider token for workload access. Neither is a replacement for signing an end user into a Claude subscription. [Claude authentication](https://platform.claude.com/docs/en/manage-claude/authentication), [Claude developer guidance](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account). DeepSeek's finding is limited to its public developer contract. [DeepSeek authentication](https://api-docs.deepseek.com/api/deepseek-api/).

OAuth buttons for Claude and DeepSeek must not imply a working connection. API billing belongs to each provider's API account and is separate from chat-plan usage. Tern must not fall back to another provider or authentication method after a request fails.

## Shared connection and request design

Keep provider identity, authentication method, model selection, and credential lifecycle separate from mail permissions. A shared app connection supplies readiness, a revision for invalidating work, the model catalogue, and the selected `AIProvider`. A service change or credential replacement invalidates requests before new credentials can be used. Store API keys in separate macOS Keychain records; store only nonsecret selection and disconnection markers in preferences.

The app must reject stale results after provider, credential, model, or permission changes. Provider switching cancels active work and clears retained chat, compose context, generated proposals, and summary caches. Mail/calendar permissions remain unchanged. Existing local writing profiles can supply style instructions to the newly selected provider. Audit previews and tests use isolated credential stores.

Every AI entry point uses the selected connection: assistant chat, compose assistance, reader summaries, calendar interpretation, writing-style learning, and mail organization. ChatGPT retains its lightweight summary-model preference; API summaries use the selected model. Unsupported image input produces a visible error before a request is sent. No adapter may silently discard required content or run tool calls from an incomplete response.

## API contracts

| Connection | Inference endpoint | Catalogue | Request format |
|---|---|---|---|
| ChatGPT | Existing Sign in with ChatGPT inference endpoint | Existing account catalogue | Responses with Tern's tool namespace |
| OpenAI API | `https://api.openai.com/v1/responses` | `GET https://api.openai.com/v1/models` | Responses with API-key bearer authentication |
| Claude | `https://api.anthropic.com/v1/messages` | `GET https://api.anthropic.com/v1/models` | Messages, API-key bearer authentication, explicit `anthropic-version` |
| DeepSeek | `https://api.deepseek.com/responses` | `GET https://api.deepseek.com/models` | Responses with API-key bearer authentication and flat function tools |

OpenAI's API model catalogue supplies identifiers and availability, not a complete capability map. Restrict selection to models whose Responses, tool, and structured-output support Tern handles. Keep account discovery separate from those compatibility rules. [OpenAI models](https://developers.openai.com/api/reference/resources/models/methods/list), [Responses usage](https://developers.openai.com/api/docs/guides/text), [function calling](https://developers.openai.com/api/docs/guides/function-calling), [structured output](https://developers.openai.com/api/docs/guides/structured-outputs).

Claude's catalogue is paginated with `has_more` and `after_id`; it includes model lifecycle and image/structured-output capabilities. Messages use `system`, `messages`, `max_tokens`, and tool `input_schema`. Structured output uses `output_config.format`; images use `image` blocks with a base64 source and media type. The reviewed current API version is `2026-10-21`, which removes `temperature`, `top_p`, and `top_k`. [Models](https://platform.claude.com/docs/en/api/models/list), [structured output](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [vision](https://platform.claude.com/docs/en/build-with-claude/vision), [versions](https://platform.claude.com/docs/en/api/versioning).

Claude streams indexed content blocks. Collect fragmented tool arguments, validate calls, and wait for the terminal message before returning a completed response. Handle errors within an otherwise successful HTTP stream, and treat a missing terminal event or token-limited answer as incomplete. [Claude streaming](https://platform.claude.com/docs/en/build-with-claude/streaming).

DeepSeek's Responses API is stateless and accepts full conversation history, function calls/results, and `text.format` JSON schemas. Flatten tool definitions and omit encrypted reasoning and server-side conversation references. Its catalogue reports input modalities; the reviewed examples offer image input on `deepseek-flash` and text input on `deepseek-v4-pro`. Preserve capability checks when catalogues change. [Responses compatibility](https://api-docs.deepseek.com/guides/responses_api/), [Responses reference](https://api-docs.deepseek.com/api/create-response/), [models](https://api-docs.deepseek.com/api/list-models/).

All transports must bound request/response sizes, cancel the underlying request, sanitize provider errors, and preserve tool-name validation. Distinguish invalid credentials, rate limits, and quota failures. DeepSeek's HTTP 402 indicates insufficient balance; Claude can report overload as HTTP 529 or a streaming error. [DeepSeek errors](https://api-docs.deepseek.com/quick_start/error_codes/), [Claude errors](https://platform.claude.com/docs/en/api/errors).

## Verification targets

Use synthetic credentials and injected transports for automated checks. These targets describe acceptance evidence; they are not a claim that live provider access has been tested.

1. Decode each provider's catalogue, preserve pagination bounds, reject malformed identifiers, and filter unsupported models/capabilities.
2. Verify endpoint and authentication isolation, structured-output encoding, image conversion, and a complete tool-call/result round trip for each API adapter.
3. Exercise split SSE chunks, malformed and truncated streams, provider errors, response limits, and cancellation. No canceled or incomplete stream may produce executable tools.
4. Verify API-key save/load/remove and failed-write behavior with isolated stores. A late key load or validation result must not restore a removed connection or replace a newly selected one.
5. Verify separate model preferences, existing ChatGPT settings, provider-switch invalidation, and unchanged mail/calendar access rules. Cover delayed responses after a provider change.
6. Confirm all assistant feature entry points use the selected provider, including automatic summaries, calendar interpretation, and writing-style work. Verify image rejection before network access for a text-only model.
7. Run affected Core and app tests, regenerate the Xcode project if needed, and build the Debug app. Review Assistant settings and onboarding for each connection choice.

The required project commands are:

```sh
swift test --package-path Packages/Core
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build build
```

Live verification, when performed, must identify which provider, model, and authentication method were exercised. A successful model-list request does not prove funded inference, streaming, tool use, or image support. Record OAuth unavailability and any untested account-dependent behavior in the completion report.
