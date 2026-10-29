# Tern

Native macOS Gmail client, codename Tern. It is built clean-room from Google's public API documentation. `docs/research/` describes the observed behavior of another client; never port decompiled code from it or copy its assets, name or design.

## Overrides of the workspace rules

- Swift files use PascalCase names that match their main type (`ThreadListView.swift`), following Swift convention. This replaces the workspace kebab-case rule for this repo.
- API boundaries use `Codable` models with explicit decoding in place of Zod.
- `~/.claude/uiux-contract/` targets web apps. Here, spacing, radius and motion values come from `App/Design/Tokens.swift`, which mirrors `design_tokens.json`. Colors and type use macOS semantic colors and text styles so dark mode, contrast settings and the accent color work.

## Layout

- `project.yml`: XcodeGen spec for the app.
- `Config/`: xcconfig files. `Secrets.xcconfig` is local and git-ignored.
- `App/`: the app target (SwiftUI views, auth glue, Info.plist, entitlements).
- `Packages/Core/`: logic, testable without the app.
  - `GmailAPI`: REST client and models. Imports only Foundation.
  - `MailStore`: GRDB schema, migrations and queries.
  - `MessageContent`: MIME part extraction, HTML sanitizing and the message page with its CSP.
  - `SyncEngine`: initial sync, history sync and the action queue.
- `docs/plans/`: milestone plans.

## Commands

```bash
xcodegen generate
swift test --package-path Packages/Core
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build build
```

Run `xcodegen generate` after editing `project.yml` and commit the regenerated `Tern.xcodeproj`.

`xcodebuild` adds the app's AppAuth pin to `Packages/Core/Package.resolved` and `swift test` removes it again. Commit the file only as `swift test` leaves it.

## Conventions

- Swift 6 language mode with complete concurrency checking. `@unchecked Sendable` and `nonisolated(unsafe)` need a comment explaining why they are safe.
- No force unwraps or `try!` outside tests.
- Auth stays in the app target behind the `AccessTokenProvider` protocol, so `Packages/Core` never imports AppAuth.
- Every change to Gmail state goes through the action queue in `SyncEngine`.
- Never log message bodies, tokens or email addresses.

## Local setup

Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and set `GOOGLE_CLIENT_ID_PREFIX`. Without it the app builds and runs but cannot sign in.
