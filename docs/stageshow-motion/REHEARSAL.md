# Rehearsal: Tern interaction motion

## Brief and plan

Improve animation and action feedback in the native macOS app while keeping its current design. The pass covers mail stars, undo notices, attachments and composer disclosures. The sidebar, top toolbar, compact message rows, colors, spacing and control sizes remain in place.

The installed stageshow skill primarily builds React product illustrations. This pass applies its motion principles to Tern's existing SwiftUI views. The `gmail` example informs the relationship between a mail action and its undo notice. The `choreography` example informs related content moving together and changes retaining their position. These are references for behavior; no demo, React kit, product styling or assets were copied into Tern.

The plan is to make the action visible at its source, let nearby content move with inserted or removed content, and leave the completed state still. Animation follows actual view or model state. Existing mail queues, send behavior, undo timing and focus callbacks retain their responsibilities.

## Implementation

The initial motion pass uses these five production files. Later behavior fixes are recorded below.

| File | Behavior |
|---|---|
| [Components.swift](../../App/Design/Components.swift) | `ternAnimation` accepts a duration, retaining the existing default. With Reduce Motion enabled, it clears inherited transaction animation and disables downstream animation. |
| [MessageListRow.swift](../../App/Views/MessageListRow.swift) | The star fades into its reserved space on hover, selection or keyboard focus; changing star state replaces the symbol in place. |
| [NoticeView.swift](../../App/Views/NoticeView.swift) | Notices enter with a short upward movement and fade, then fade out. The notice ID drives animation so unrelated changes do not restart it. |
| [AttachmentStrip.swift](../../App/Compose/AttachmentStrip.swift) | Attachment and failure chips arrive and leave with a short offset and fade while neighbors move with them. The attachment count transitions when it changes. |
| [ComposeView.swift](../../App/Compose/ComposeView.swift) | Attachment-strip, assistant and Cc/Bcc disclosures transition with their surrounding layout. The quote disclosure rotates the same chevron. |

Durations use `Tokens.Motion`, and offsets use `Tokens.Space`. Fast star feedback uses the fast motion token; disclosures use the existing base duration. No animation creates a success state or delays the underlying action.

Reduce Motion disables the shared animations. Added content and symbol transitions use identity transitions, so the final state appears immediately without positional motion or number rolling. The quote chevron still indicates the current disclosure state.

## Checked states and limits

Native hosted screenshots and interaction checks replace stageshow's browser film tooling for this SwiftUI app. The initial run produced eight PNGs with synthetic data: composer views at 640 and 780 points, mail at 440 points, light and dark settled states, and samples 40 milliseconds into attachment arrival, attachment removal and notice arrival. The [initial screenshot manifest](../../build/Verification/stageshow-motion/screenshots/manifest.json) maps each PNG to its capture state. The reviewer examined all eight and found no actionable frame defects. The Reduce Motion follow-up produced [ten further captures](../../build/Verification/reduce-motion/screenshots/manifest.json), including quote disclosure states; the reviewer examined all ten without actionable findings.

| Flow | Checked | Remaining limits |
|---|---|---|
| Mail star | The row's native Star accessibility action updated the actual model. Light and dark settled mail views were inspected. | Hover and keyboard-star transitions were not separately visually exercised. |
| Notices | Arrival at 40 milliseconds and settled notices were captured. Native Dismiss worked, and an old notice timer did not dismiss its replacement. Real archive removed the synthetic row; native notice Undo restored it. | Continuous entrance, exit and interruption footage was not recorded. |
| Attachments | Two files were added. Native removal of `agenda.txt` left `notes.txt`. The follow-up below checked the actual Quick Look panel, pagination, native close and Space reopening, plus failure Retry, Remove and Keep actions. | Recovery failures were induced with a missing local file and a SQLite DELETE refusal. Live Gmail failures were not exercised. |
| Composer | After each actual Cc and Bcc disclosure, the current native field editor held focus. Native Show/Hide Quoted Text actions changed the disclosure and retained the quoted content. Regular, narrow and quote captures were inspected. The installed initial Release also passed manual Cc/Bcc focus and assistant open/close checks with the real system setting enabled. | Sender transitions were not separately visually exercised. The manual installed-app checks preceded the follow-up fix. |
| Reduce Motion | Real macOS and SwiftUI environment values were checked while the same hosted view remained mounted through On, Off and On. The visible probe rectangle produced zero interpolated offsets with the fix under Reduce Motion, 18 with motion enabled, then zero after re-enabling Reduce Motion. | The probe measures shared animation behavior; it does not record every production transition continuously. |

Sampled frames establish layout and selected motion states. The follow-up also measures rendered interpolation with an `AnimatableModifier` and checks downstream transaction flags. No continuous recording was made. The React `film.mjs --gate` check was not run, and no film-gate result is claimed.

## Initial verification and delivery

Initial evidence is under [build/Verification/stageshow-motion](../../build/Verification/stageshow-motion/).

- Debug `build-for-testing` passed: `debug-build-final.log`.
- Both native interaction tests passed: `native-final.log` and `native-final.xcresult`.
- All 46 regression tests passed across `ComposeModelTests`, `MessageListTests` and `MailToolbarObservationTests`: `regression.log` and `regression.xcresult`.
- The universal Release build passed for Apple silicon and Intel: `release-build.log`.

The initial run totaled 48 passing tests. The first test build exposed the read-only Reduce Motion environment value. The harness also needed to wait for initial To-field focus and invoke the row's custom Star accessibility action instead of looking for a child button. Those harness corrections preceded the passing run. This initial verification required no production fixes, and review found no actionable frame defects. Runtime Reduce Motion remained unchecked at that point; the follow-up below closes that gap.

Initial Release revision `da78c4572c9ddcbb910437957bd73d3ab1670a71` was installed at `/Users/developer/Applications/Tern.app`. Tern quit normally before the update and relaunched with its populated Inbox, sidebar and top toolbar. The signature, signing requirement and OAuth configuration matched the previous app. The previous app is backed up at `build/Previous/Tern-before-stageshow-da78c457.app`; the [initial delivery record](../../build/Verification/stageshow-motion/delivery.json) records the executable hash and checks. SwiftPM resolution ran after Xcode and left Core dependency pins unchanged.

The initial build came from the isolated `/tmp/tern-stageshow-motion` checkout. Concurrent assistant, calendar and reader edits in the main checkout were preserved and excluded from that build. Live mail delivery and calendar writes were not exercised.

## Reduce Motion follow-up

The runtime audit found an inherited animation leak: `.animation(nil, value:)` did not clear an outer animation when its watched value stayed unchanged. With the real macOS setting enabled and SwiftUI reading `true`, the rendered baseline retained the inherited animation, left `disablesAnimations` false and produced eight intermediate offsets. The earlier transaction-only baseline established propagation; the rendered baseline established movement.

Commit `3a85c14` fixes the shared helper by clearing transaction animation and setting `disablesAnimations` when Reduce Motion is enabled. Layout, tokens and design remain unchanged. Parent commit `71ca95c` contains the independent sidebar hover correction. Unrelated assistant, calendar, reader, settings and token edits remain preserved and excluded from this fix.

Evidence is under [build/Verification/reduce-motion](../../build/Verification/reduce-motion/):

- `baseline.log` records the transaction-only failure; `rendered-baseline.log` and `rendered-baseline.xcresult` record the eight intermediate offsets before the fix.
- `live.log` and `live.xcresult` record the passing runtime audit. System Settings changed the real preference while one SwiftUI host stayed mounted: reduced motion had no inherited animation and zero intermediate offsets; ordinary motion retained animation and produced 18; re-enabling Reduce Motion returned to zero. The probe also required the final rendered endpoint.
- The same audit exercised Cc/Bcc focus, two attachments and removal, native quote Show/Hide, scoped native Star, archive and native notice Undo, notice replacement and Dismiss. `screenshots/manifest.json` maps the ten reviewed PNGs.
- `normal.log` and `normal.xcresult` record both ordinary native tests passing with the opt-in audit skipped.

The preference changed through System Settings, without environment injection. The original Off preference was restored after the live audit; `runtime.json` records the setting changes and checks. At that time, Quick Look and failure transitions were outside the visual checks. The attachment follow-up below covers them.

The universal Release for `3a85c14d2cda00f86bb7346c3a06546658deb49c` passed and was installed at `/Users/developer/Applications/Tern.app`. Signature, signing requirement and OAuth configuration matched the previous app. The previous app is backed up at `build/Previous/Tern-before-reduce-motion-3a85c14d.app`; [delivery.json](../../build/Verification/reduce-motion/delivery.json) records its hash and checks.

The installed app was launched with the original Off setting, then tested after enabling Reduce Motion while it remained running. Cc and Bcc disclosures focused their native fields, and the compose assistant opened, focused its input and closed. The untouched test composer closed normally. Reduce Motion was restored to Off, and Tern was left open on Inbox with no dialog. No real message was sent, archived or deleted during this installed-app check. SwiftPM resolution ran after the Xcode checks and left Core dependency pins unchanged.

## Attachment Quick Look and recovery follow-up

Native attachment checks reproduced four failures: a removed attachment could open after its pending preview resumed; an earlier preview request could replace a newer selection; a suspended file copy could recreate a removed attachment's temporary file; and a failed removal deleted the preview copy even though Keep retained the attachment.

Commit `2dc163e` fixes three production files. `AttachmentStrip.swift` cancels obsolete preview work and checks which request still owns the selection. `OutgoingAttachmentFiles.swift` invalidates pending copies on removal or close and isolates their temporary paths. `ComposeModel.swift` removes the preview copy only after the attachment's stored removal succeeds. The reproduced failures and passing regression checks give high confidence in these fixes. The design is unchanged.

The acceptance run hosted the real `ComposeView` with synthetic AuditGmail accounts and inspected the actual shared Quick Look panel. It checked selected filenames and file bytes, two preview items reducing to one, Right/Left pagination, native panel close followed by a real Space reopening, and native Remove dismissing the preview. The compose window had to remain visible after closing Quick Look.

Recovery checks restored a missing source file, invoked native Retry and verified the attachment arrived. Native Remove dismissed another failed import. A disk-backed SQLite DELETE refusal then produced the removal failure card: Keep retained both the attachment and its readable preview file; Retry removed the attachment after the refusal was lifted. These fixtures performed no live provider or mail writes.

Run the operator acceptance with `--ui-audit --attachment-audit --attachment-live`. The two operator tests wait for CUA to close the actual panel and press Space; they observe the resulting native state. The three race regressions also run with `--ui-audit --attachment-audit` alone. Their nonlive `orderOut` call is cleanup for test isolation and provides no evidence about native close behavior.

Evidence is under [build/Verification/attachment-flows](../../build/Verification/attachment-flows/):

- `clean-baseline.log` and `clean-baseline.xcresult` record the reproduced preview and cache failures before the fix.
- `native-final.log` and `native-final.xcresult` record 25 passing tests: 18 ComposeModel, two MotionInteraction and five AttachmentInteraction tests. The opt-in runtime Reduce Motion test was skipped in this run; its earlier real-system audit remains recorded above.
- `captures-final.log` and `captures-final.xcresult` record all five attachment tests passing again after a capture-only timing correction. The helper now waits 350 milliseconds for the native view and chip transition to settle. The [final capture manifest](../../build/Verification/attachment-flows/captures-final/manifest.json) maps ten PNGs. Independent review inspected all ten and found no material source issues or visual defects.

Continuous recording, the browser film gate and live Gmail failures were outside this follow-up. Universal signed Release packaging and installation remain pending.
