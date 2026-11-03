# Assistant experience

Date: 2026-10-30

The user requested concise, beautifully formatted answers, embedded diagrams when useful, and a more considered chat sidebar. Implementation and verification are complete.

## Response presentation

Lead with the answer. Default to one or two short paragraphs or three to five brief bullets, usually under 150 words; explicit requests and necessary detail take priority. Preserve evidence, dates, uncertainty, and retrieval limits. Use restrained Markdown hierarchy and let mail cards and draft controls carry their own details.

Render small Mermaid flowcharts natively, with bounded nodes, edges, and labels. Support simple workflows and decisions without loading scripts, images, or remote resources. Unsupported or incomplete diagrams remain readable code. The main conclusion must remain understandable without the diagram.

## Sidebar

Keep identity, chat controls, and mail scope together in a compact header. Give suggestions, the transcript, and the composer distinct spacing and surfaces. Preserve shared conversation/input state, source navigation, stop/retry, draft review, calendar actions, keyboard operation, and scroll position while reading earlier messages.

Use the app's existing design tokens and macOS semantic type and colors. Inspect minimum-width and detached layouts, including short windows and light/dark appearance.

## Implementation and verification

Work is split between sidebar presentation, Markdown/diagrams, and response instructions, followed by independent review. Existing settings changes in this shared checkout remain intact. Validation uses a disposable source snapshot to avoid changes from other active work affecting the build.

The Debug build and all 36 focused tests in five suites passed: `AssistantMarkdownTests`, `AssistantModelTests`, `AssistantScrollTrackingTests`, `AssistantSidebarLayoutTests`, and `SidebarLayoutTests`. Log: `/tmp/tern-agent-experience-tests.log`.

Regression coverage includes closed versus unfinished Mermaid fences, whole-block fallback for unsupported or oversized input, branch/merge preservation, narrow diagrams, and arrows that skip ranks in four directions. Native pane tests retain the existing width/restoration checks. The diagram parser supports eight nodes and twelve arrows; unsupported Mermaid remains code.

Independent review resolved accessible sender labels, toolbar focus, arrow routing, and label measurements. The conversation view uses smaller builders and a single comparable content snapshot to observe the same streaming and tool-result changes without exceeding Swift's expression-checking limit.

Validation used an isolated temporary source snapshot. Concurrent Calendar implementation files were excluded after their unfinished timeline view failed compilation. Existing settings changes are included; this work does not certify the concurrent Calendar changes.

Native inspection used an isolated preview with synthetic connection state and streamed, canned responses. Checks covered the 320-point minimum and 380-point default widths, light/dark appearance, a 360-point height, a 720-point detached window, diagram/source switching, source disclosure, Markdown tables/lists/quotes, initial composer focus, and Command-Return sending. The detached window retained the conversation and unfinished input. The preview build passed in `/tmp/tern-agent-experience-preview.log`; it is not a live provider check.

The running preview is `/tmp/tern-agent-experience-build/Build/Products/Debug/Tern.app`, bundle ID `dev.tern.agent.experience.preview`. Its custom entry point exists only in the disposable preview; production assistant files match the verified source. The production entry point is restored in the source snapshot, and the verified normal app is saved as `VerifiedTern.app` beside it. Spoken VoiceOver, older macOS versions, and live model adherence to the new writing instructions were not exercised.
