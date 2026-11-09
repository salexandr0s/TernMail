# AI provider connections

Tern's assistant has five connection choices: ChatGPT sign-in, Claude (CLI), OpenAI API, Claude API, and DeepSeek API. The selected connection supplies every AI feature. Each service retains a separate model choice. Claude (CLI) runs the user's installed official Claude Code; the three API connections use the user's keys.

## Scope and authentication

Preserve Tern's existing ChatGPT registration, OAuth verification, token rotation, revocation, and Keychain record. Add API-key connections for OpenAI, Anthropic, and DeepSeek. Add Claude subscription sign-in through the official CLI's own authentication flow without extracting, importing, or storing its credentials.

Public provider documentation was reviewed on November 3, 2026:

| Provider | Supported connection in Tern | OAuth finding |
|---|---|---|
| OpenAI | ChatGPT OAuth or an OpenAI API key | Retain the existing Sign in with ChatGPT implementation and its plan-access checks. |
| Anthropic | Official Claude Code CLI or a separate API key | The CLI owns OAuth. Tern does not register a native Claude subscription OAuth client. Running the unmodified CLI is subject to Anthropic's hosting conditions. |
| DeepSeek | API key | Public API documentation describes bearer API keys; no public third-party OAuth registration/token-exchange contract for inference was found. |

Anthropic's hosting rules require the unmodified published binary, access to its built-in authentication methods, and each end user authenticating and paying under their own agreement. They prohibit reselling or intermediating usage and require acceptance of the Commercial Terms. The credential rules expressly preserve end-user sign-in to the unmodified CLI in this hosting arrangement. Do not describe this as permission to collect subscription tokens or offer an independent Claude OAuth client. [Claude Code hosting and credential rules](https://code.claude.com/docs/en/legal-and-compliance#can-customers-offer-claude-code-in-their-products).

Anthropic's App Attest issues device tokens billed to the registered application's workspace. Workload Identity Federation exchanges an identity-provider token for workload access. Neither supplies native subscription sign-in. [Claude API authentication](https://platform.claude.com/docs/en/manage-claude/authentication). DeepSeek's finding is limited to its public developer contract. [DeepSeek authentication](https://api-docs.deepseek.com/api/deepseek-api/).

Claude (CLI) uses the account and billing active in the CLI; subscription eligibility and organization restrictions still apply. API billing remains separate from chat-plan usage. Tern must not fall back to another service or authentication method after a request fails.

## Claude CLI connection and helper

`AIService.claudeCode` appears as **Claude (CLI)**, separately from **Claude API**. **Connect Claude Code** opts in to using the active CLI identity and its billing. **Sign In…** launches the official sign-in flow. **Check Again** probes installation without enabling a connection; **Check Connection** verifies the connected account. Disconnect cancels Tern's work and disables local access without logging out the external CLI. Authentication and any refresh tokens stay under Claude Code's control. [Official installation](https://code.claude.com/docs/en/setup#install-claude-code), [authentication](https://code.claude.com/docs/en/authentication).

The sandboxed app calls the bundled `ClaudeHelper` XPC service (`dev.tern.mail.ClaudeHelper`). The helper runs outside the sandbox and launches the installed official CLI. It is included in the direct-distribution build at `Contents/XPCServices/ClaudeHelper.xpc`; this design makes no Mac App Store compatibility claim. XcodeGen defines the helper, its embedding/signing dependency, and `ClaudeHelperTests`. Build and test it through the Tern scheme.

The locator accepts the native Claude Code binary signed with Anthropic's Developer ID. npm JavaScript installations and shell wrappers do not pass this check. Release requires a Team ID signature shared by the app and helper. Debug alone permits ad-hoc signing, with exact host code-hash validation. Configure `TERN_CODE_SIGN_IDENTITY` and `TERN_DEVELOPMENT_TEAM` in the ignored `Config/Secrets.xcconfig`.

Require CLI support for the safety options before sending content. Run noninteractive requests with CLI action tools disabled, startup customizations restricted, and session persistence disabled. Safe mode preserves authentication; `--bare` cannot supply this OAuth route because it skips OAuth credentials. CLI settings and managed-policy behavior require explicit verification on supported versions. [CLI options](https://code.claude.com/docs/en/cli-reference), [programmatic operation](https://code.claude.com/docs/en/headless).

The adapter supplies bounded context and an output schema. CLI built-in actions stay disabled; its `StructuredOutput` mechanism may validate the response. Tern validates returned action names, arguments, and call limits before its existing mail/calendar tools can run. Existing review steps still govern draft sending and calendar/task saves. A valid result envelope and successful process exit are both required; cancellation, malformed output, missing results, or failed exits cannot yield executable actions.

Offer **Account default**, **Sonnet**, **Opus**, and **Haiku** as CLI aliases. These are not an account model catalogue or a promise that every alias is available. Account access and CLI resolution determine the actual model. The other connections continue to use live catalogues.

## Shared connection and request design

Keep provider identity, authentication method, model selection, and credential lifecycle separate from mail permissions. A shared app connection supplies readiness, a revision for invalidating work, the model catalogue, and the selected `AIProvider`. A service change or credential replacement invalidates requests before new credentials can be used. Store API keys in separate macOS Keychain records; store only nonsecret selection and disconnection markers in preferences.

The app must reject stale results after provider, credential, model, or permission changes. Provider switching cancels active work and clears retained chat, compose context, generated proposals, and summary caches. Mail/calendar permissions remain unchanged. Existing local writing profiles can supply style instructions to the newly selected provider. Audit previews and tests use isolated credential stores.

Every AI entry point uses the selected connection: assistant chat, compose assistance, reader summaries, calendar interpretation, writing-style learning, and mail organization. ChatGPT retains its lightweight summary-model preference; Claude (CLI) and API summaries use the selected model. Unsupported image input produces a visible error before a request is sent. No adapter may silently discard required content or run tool calls from an incomplete response.

## API contracts

| Connection | Inference endpoint | Catalogue | Request format |
|---|---|---|---|
| ChatGPT | Existing Sign in with ChatGPT inference endpoint | Existing account catalogue | Responses with Tern's tool namespace |
| OpenAI API | `https://api.openai.com/v1/responses` | `GET https://api.openai.com/v1/models` | Responses with API-key bearer authentication |
| Claude API | `https://api.anthropic.com/v1/messages` | `GET https://api.anthropic.com/v1/models` | Messages, API-key bearer authentication, explicit `anthropic-version` |
| DeepSeek API | `https://api.deepseek.com/responses` | `GET https://api.deepseek.com/models` | Responses with API-key bearer authentication and flat function tools |

OpenAI's API model catalogue supplies identifiers and availability, not a complete capability map. Restrict selection to models whose Responses, tool, and structured-output support Tern handles. Keep account discovery separate from those compatibility rules. [OpenAI models](https://developers.openai.com/api/reference/resources/models/methods/list), [Responses usage](https://developers.openai.com/api/docs/guides/text), [function calling](https://developers.openai.com/api/docs/guides/function-calling), [structured output](https://developers.openai.com/api/docs/guides/structured-outputs).

Claude's catalogue is paginated with `has_more` and `after_id`; it includes model lifecycle and image/structured-output capabilities. Messages use `system`, `messages`, `max_tokens`, and tool `input_schema`. Structured output uses `output_config.format`; images use `image` blocks with a base64 source and media type. The reviewed current API version is `2026-10-21`, which removes `temperature`, `top_p`, and `top_k`. [Models](https://platform.claude.com/docs/en/api/models/list), [structured output](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [vision](https://platform.claude.com/docs/en/build-with-claude/vision), [versions](https://platform.claude.com/docs/en/api/versioning).

Claude streams indexed content blocks. Collect fragmented tool arguments, validate calls, and wait for the terminal message before returning a completed response. Handle errors within an otherwise successful HTTP stream, and treat a missing terminal event or token-limited answer as incomplete. [Claude streaming](https://platform.claude.com/docs/en/build-with-claude/streaming).

DeepSeek's Responses API is stateless and accepts full conversation history, function calls/results, and `text.format` JSON schemas. Flatten tool definitions and omit encrypted reasoning and server-side conversation references. Its catalogue reports input modalities; the reviewed examples offer image input on `deepseek-flash` and text input on `deepseek-v4-pro`. Preserve capability checks when catalogues change. [Responses compatibility](https://api-docs.deepseek.com/guides/responses_api/), [Responses reference](https://api-docs.deepseek.com/api/create-response/), [models](https://api-docs.deepseek.com/api/list-models/).

All transports must bound request/response sizes, cancel the underlying request, sanitize provider errors, and preserve tool-name validation. Distinguish invalid credentials, rate limits, and quota failures. DeepSeek's HTTP 402 indicates insufficient balance; Claude can report overload as HTTP 529 or a streaming error. [DeepSeek errors](https://api-docs.deepseek.com/quick_start/error_codes/), [Claude errors](https://platform.claude.com/docs/en/api/errors).

## Verification targets

Use synthetic credentials and injected transports for offline checks. The targets below define expected coverage; recorded live results and remaining gaps follow them.

1. Decode ChatGPT and API catalogues, preserve pagination bounds, reject malformed identifiers, and filter unsupported models/capabilities.
2. Verify endpoint and authentication isolation, structured-output encoding, image conversion, and a complete tool-call/result round trip for each API adapter.
3. Exercise split SSE chunks, malformed and truncated streams, provider errors, response limits, and cancellation. No canceled or incomplete stream may produce executable tools.
4. Verify API-key save/load/remove and failed-write behavior with isolated stores. A late key load or validation result must not restore a removed connection or replace a newly selected one.
5. Verify separate model preferences, existing ChatGPT settings, provider-switch invalidation, and unchanged mail/calendar access rules. Cover delayed responses after a provider change.
6. Confirm all assistant feature entry points use the selected provider, including automatic summaries, calendar interpretation, and writing-style work. Verify image rejection before network access for a text-only model.
7. Run affected Core and app tests, regenerate the Xcode project if needed, and build the Debug app. Review Assistant settings and onboarding for each connection choice.
8. Verify helper embedding, Team ID signing, Debug-only ad-hoc code-hash checks, XPC caller validation, native executable signature checks, supported CLI options, startup isolation, output bounds, cancellation, and process cleanup. Keep the main app sandbox enabled. Test absent, unsupported, signed-out, and failed CLI installations with injected processes.
9. Verify explicit CLI opt-in, official sign-in, local-only disconnect, changed identity/billing detection, model aliases, and stale-result rejection after switching or disconnecting. Test structured action round trips and reject unadvertised or malformed actions before tool execution.

The required project commands are:

```sh
xcodegen generate
swift test --package-path Packages/Core
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build build
```

`python3 scripts/test-claude-cli.py` builds and runs offline helper and connection regressions. `--live` explicitly enables hosted tests through the signed, sandboxed app using the existing CLI subscription, with synthetic prompts, tool results, and an in-memory image. It sends no real mail and consumes the connected account's usage. `--ui` adds the native Assistant settings check on an unlocked Mac; `--skip-build` reuses the current test build. Results are written to `build/claude-cli/validation/`.

Use `python3 scripts/test-claude-cli.py --standalone-live-ui` separately for the normal app's live UI check. It uses the existing CLI subscription and sends only a synthetic prompt. The script builds the UI test, rebuilds the normal app to remove Xcode's injected test entitlements, and verifies the app's sandbox entitlements before and after the test. It rejects temporary sandbox exceptions or `get-task-allow`. This option requires an unlocked Mac and cannot be combined with `--live` or `--ui`.

## Recorded verification

On November 3, 2026, 821 Core tests across 133 suites passed. The initial integrated run passed 30 app tests across four suites, including two live tests, plus 11 helper tests and one native Settings UI test.

The live tests used official Claude Code 2.1.226 with an existing claude.ai Max sign-in. They verified streaming through the sandboxed app and XPC helper, requests with Tern's full mail/calendar tool catalogue, a synthetic tool-result round trip, structured output, and image input. An unrelated signed test app was rejected by the helper.

The standalone live UI test passed, including cleanup and local disconnect. A normal app build connected through the UI using the existing Claude Max OAuth account, selected Haiku, and returned the exact expected synthetic response. The script verified the tracked sandbox entitlements before and after the test, with no Xcode test exceptions or `get-task-allow`. Reproduce it with `python3 scripts/test-claude-cli.py --standalone-live-ui`. Local evidence is in `build/claude-cli/validation/checks-c48294f588.log`, its matching result bundle, and `standalone-entitlements-c48294f588.plist` in that directory.

These tests used an existing CLI account. Fresh browser consent and token refresh were not exercised live. Release Team ID signing and notarization were not verified. The results do not establish compatibility with every account or CLI version.

Live verification, when performed, must identify which provider, model, and authentication method were exercised. A successful model-list request does not prove funded inference, streaming, tool use, or image support. Record DeepSeek's public OAuth limitation and any untested account-dependent behavior in the completion report.
