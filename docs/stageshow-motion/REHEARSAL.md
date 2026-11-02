# Rehearsal: Tern interaction motion

## Brief and plan

Improve animation and action feedback in the native macOS app while keeping its current design. The pass covers mail stars, undo notices, attachments and composer disclosures. The sidebar, top toolbar, compact message rows, colors, spacing and control sizes remain in place.

The installed stageshow skill primarily builds React product illustrations. This pass applies its motion principles to Tern's existing SwiftUI views. The `gmail` example informs the relationship between a mail action and its undo notice. The `choreography` example informs related content moving together and changes retaining their position. These are references for behavior; no demo, React kit, product styling or assets were copied into Tern.

The plan is to make the action visible at its source, let nearby content move with inserted or removed content, and leave the completed state still. Animation follows actual view or model state. Existing mail queues, send behavior, undo timing and focus callbacks retain their responsibilities.

## Implementation

Five production files contain this pass:

| File | Behavior |
|---|---|
| [Components.swift](../../App/Design/Components.swift) | `ternAnimation` accepts a duration, retaining the existing default and Reduce Motion handling. |
| [MessageListRow.swift](../../App/Views/MessageListRow.swift) | The star fades into its reserved space on hover, selection or keyboard focus; changing star state replaces the symbol in place. |
| [NoticeView.swift](../../App/Views/NoticeView.swift) | Notices enter with a short upward movement and fade, then fade out. The notice ID drives animation so unrelated changes do not restart it. |
| [AttachmentStrip.swift](../../App/Compose/AttachmentStrip.swift) | Attachment and failure chips arrive and leave with a short offset and fade while neighbors move with them. The attachment count transitions when it changes. |
| [ComposeView.swift](../../App/Compose/ComposeView.swift) | Attachment-strip, assistant and Cc/Bcc disclosures transition with their surrounding layout. The quote disclosure rotates the same chevron. |

Durations use `Tokens.Motion`, and offsets use `Tokens.Space`. Fast star feedback uses the fast motion token; disclosures use the existing base duration. No animation creates a success state or delays the underlying action.

Reduce Motion disables the shared animations. Added content and symbol transitions use identity transitions, so the final state appears immediately without positional motion or number rolling. The quote chevron still indicates the current disclosure state.

## Checked states and limits

Native hosted screenshots and interaction checks replace stageshow's browser film tooling for this SwiftUI app. The final run produced eight PNGs with synthetic data: composer views at 640 and 780 points, mail at 440 points, light and dark settled states, and samples 40 milliseconds into attachment arrival, attachment removal and notice arrival. The [screenshot manifest](../../build/Verification/stageshow-motion/screenshots/manifest.json) maps each PNG to its capture state. The reviewer examined all eight and found no actionable frame defects.

| Flow | Checked | Remaining limits |
|---|---|---|
| Mail star | The row's native Star accessibility action updated the actual model. Light and dark settled mail views were inspected. | Hover and keyboard-star transitions were not separately visually exercised. |
| Notices | Arrival at 40 milliseconds and settled notices were captured. Native Dismiss worked, and an old notice timer did not dismiss its replacement. | Continuous entrance, exit and interruption footage was not recorded. |
| Attachments | Two files were added. Native removal of `agenda.txt` left `notes.txt`. Arrival, removal and settled frames were inspected. | Quick Look and failure transitions were not separately visually exercised. |
| Composer | After each actual Cc and Bcc disclosure, the current native field editor held focus. Regular and narrow composer captures were inspected. | Sender, quote and assistant transitions were not separately visually exercised. |
| Reduce Motion | Source review confirmed the shared animation guard and identity content transitions. | The SDK exposes `accessibilityReduceMotion` as read-only, so the harness could not inject it. The OS setting was not changed; runtime Reduce Motion behavior remains unverified. |

These sampled frames establish layout and selected motion states. They do not replace a continuous recording. The React `film.mjs --gate` check was not run, and no film-gate result is claimed.

## Verification record

All evidence is under [build/Verification/stageshow-motion](../../build/Verification/stageshow-motion/).

- Debug `build-for-testing` passed: `debug-build-final.log`.
- Both native interaction tests passed: `native-final.log` and `native-final.xcresult`.
- All 46 regression tests passed across `ComposeModelTests`, `MessageListTests` and `MailToolbarObservationTests`: `regression.log` and `regression.xcresult`.
- The universal Release build passed for Apple silicon and Intel: `release-build.log`.

The final total is 48 passing tests. The first test build exposed the read-only Reduce Motion environment value. The harness also needed to wait for initial To-field focus and invoke the row's custom Star accessibility action instead of looking for a child button. Those harness corrections preceded the passing run. Testing required no production fixes, and review found no actionable frame defects. Existing behavior outside the exercised transitions was reviewed; the unchecked states above remain explicit limits.

Release revision `da78c4572c9ddcbb910437957bd73d3ab1670a71` is installed at `/Users/developer/Applications/Tern.app`. Tern quit normally before the update and relaunched with its populated Inbox, sidebar and top toolbar. The signature, signing requirement and OAuth configuration matched the previous app. The previous app is backed up at `build/Previous/Tern-before-stageshow-da78c457.app`; [delivery.json](../../build/Verification/stageshow-motion/delivery.json) records the executable hash and checks. SwiftPM resolution ran after Xcode and left Core dependency pins unchanged.

The build came from the isolated `/tmp/tern-stageshow-motion` checkout. Concurrent assistant, calendar and reader edits in the main checkout were preserved and excluded from this installed build. Live mail delivery, calendar writes and runtime Reduce Motion were not exercised.
