# Settings and copy polish

## Scope

Review all app-owned visible copy with `avoid-ai-writing`, then refine the existing Settings interface. Keep the approved reader density. Preserve mail content, native action names, shortcuts, preference defaults, account behavior, and meaningful warnings. Do not add new settings.

## Plan

1. Review titles, labels, descriptions, help, errors, and confirmation dialogs. Remove repeated instructions and unnecessary descriptions; retain consequences, limits, and uncertainty. Copy work has separate owners for mail views, compose, support views, and model errors.
2. Keep General and Accounts as native tabs. Use compact sections and aligned controls, short helpers, a direct link to the existing shortcut reference, shorter account rows, and a pinned Add Account action. Preserve scrolling, accessible labels, sign-in progress/errors, and sign-out confirmation.
3. Review changed copy and behavior, inspect Settings in light and dark mode, check menus and keyboard access, run the appropriate app/core checks, commit, and update the handoff.

## Design constraints

- General exposes Undo Send (5, 10, 20, or 30 seconds; default 10) and single-key shortcuts (off by default).
- Accounts supports Add Account, Sign In Again, and Sign Out. It must show unavailable sign-in, errors, and progress without clipping the actions.
- Use existing semantic macOS colors and text styles, shared spacing/radius/motion tokens, and native controls.
- Account names may truncate with full text in help; messages and errors wrap.
- Sign-out text must retain the deletion of local mail/pending changes, unsent-message counts, and snoozed conversations remaining archived.

The plan received a read-only review. No blockers were found; wrapping errors and keeping the account footer visible are the main layout checks.

## Result

The copy review covered mail, compose, account, label, snooze, shortcut, sign-in, and error surfaces. It removed repeated descriptions and shortened wording while preserving warnings and uncertainty. Existing tests that assert changed messages were updated; no copy-only tests were added.

Settings now uses a 520-by-280-point content area, compact groups, aligned native controls, and a direct shortcut reference link. Account rows show identity and actions side by side. Add Account stays in a footer while accounts and errors scroll. The switch has an explicit accessibility label and hint.

Review found that sign-in errors during signed-in use appeared only in the mail window. They now also remain visible in Settings, and signing out clears stale sign-in errors. The Debug-only `--ui-audit-reauth` flag exposes the synthetic account's reauthentication row for inspection.

## Verification

- Debug build and hosted app tests passed: 37 tests in 9 suites. Log: `/tmp/tern-settings-final-tests.log`.
- Core tests passed: 205 tests in 31 suites. Log: `/tmp/tern-settings-core-tests-final.log`. The first run found two stale expected strings; both were corrected before the passing run.
- Live checks covered General and Accounts in light/dark mode, Undo Send choices, the shortcut reference link, account-specific sign-out confirmation and cancellation, and failed-reauthentication feedback with the footer visible.
- Accessibility inspection confirmed the switch name/hint and account-specific action names. Cmd-comma opens Settings. Full keyboard traversal and spoken VoiceOver were not exercised.
- Long errors, empty accounts, sign-in progress, and account-name truncation were reviewed in source. No real OAuth or Gmail request was used. Release was not rebuilt for this follow-up.
- Final source review found no remaining blockers. `git diff --check` passed.

Commits: `f0e3793` for copy and `473cd79` for Settings. No work remains in this pass; the first design pass's reader density is unchanged.
