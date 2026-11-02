# First-run onboarding

Tern opens setup when the account store is empty on its first successful launch.
The flow introduces Tern, connects Google accounts, offers ChatGPT, saves key
preferences, and ends with a review before opening the mailbox.

Setup fills a compact native window with a 1000 × 600 point content area. Open
Tern expands that same window into the mailbox and restores its normal toolbar
and resizing controls. The expansion respects Reduce Motion and stays within the
current display. Normal launches after setup keep the existing window behavior.

- Google supports repeated account additions, cancellation, retry, and reconnecting
  expired accounts. At least one connected account is required to continue.
- ChatGPT uses the existing account connection and model discovery. Mail access
  remains off until the user enables individual accounts. Setup can continue
  without ChatGPT.
- Preferences share the keys used by Settings: default sending account, Undo Send,
  remote images, and single-key shortcuts. Notification permission is requested
  only after the user chooses Enable.
- Progress is saved under `tern.onboarding.v1`. Connecting the first account does
  not finish setup. Only Open Tern on the final screen completes it. Existing
  installations with accounts bypass setup; incomplete setup resumes after a
  relaunch. Completion requires at least one account with a usable connection.

## Design review

The first improvement pass refined the card height, progress rail, compact layout,
transition behavior, scroll position, and accessibility labels. The second refined
the primary action on each screen, marked ChatGPT as optional, used contrast-aware
surfaces, and made the final summary reflect saved preferences and connection
recovery states. Native renderings were inspected for all five screens, plus
Preferences at 720 × 480 in high-contrast dark appearance.

## Verification

`TernTests` covers saved progress, migration, completion guards, hosted rendering,
and restoring normal window controls without resizing an existing user's window.
`TernUITests` exercises the empty first-run path and a two-account journey through
ChatGPT skipping, preference edits, back navigation, and expanding into the mailbox.
The existing Google, ChatGPT, and assistant tests cover authentication and account
access behavior. Live provider consent and the macOS notification prompt require
interactive verification with a real account.

```sh
xcodegen generate
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug \
  -derivedDataPath build test \
  -only-testing:TernTests/OnboardingStateTests \
  -only-testing:TernTests/OnboardingFlowTests \
  -only-testing:TernTests/GoogleAuthTests \
  -only-testing:TernTests/ChatGPTConnectionTests \
  -only-testing:TernTests/AssistantModelTests \
  -only-testing:TernUITests/OnboardingUITests
```

Debug previews use `--ui-audit --ui-audit-onboarding` for an empty first run or
`--ui-audit --ui-audit-onboarding-connected` for two sample accounts. Add
`--ui-audit-onboarding-step=welcome` (or `google`, `chatGPT`, `preferences`, `ready`)
to choose a screen. Ordinary previews disable provider sign-in and permission
requests, isolate preferences, and do not persist onboarding completion. Tests
attach native screenshots to the Xcode result bundle.
