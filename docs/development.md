# Developing Tern

Tern targets macOS 26 and uses Swift 6 language mode with complete concurrency checking. The Core package requires Swift tools 6.2. Use Xcode 26 or later with the macOS 26 SDK.

The generated `Tern.xcodeproj` is committed, so a fresh clone opens directly in Xcode. [XcodeGen](https://github.com/yonaskolb/XcodeGen) is needed when changing the project specification:

```sh
brew install xcodegen
xcodegen generate
```

Regenerate and commit the Xcode project after editing `project.yml` or adding source files.

## Google sign-in

Tern uses a Google OAuth client configured for its custom URL scheme. It does not include a shared client configuration.

1. Create or select a Google Cloud project and enable Gmail API. Enable People API for contact suggestions and photos, Google Calendar API for calendars, and Google Tasks API for tasks.
2. Configure the OAuth consent screen and its data-access scopes. For personal development, use a testing audience and add each Google account you intend to connect as a test user.
3. Create an OAuth client of type **iOS** with bundle ID `dev.tern.mail`. This matches Tern's custom-scheme callback. Google's [iOS and macOS configuration guide](https://developers.google.com/identity/sign-in/ios/start-integrating#get_an_oauth_client_id) describes that client type.
4. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`. Set `GOOGLE_CLIENT_ID_PREFIX` to the portion of your client ID before `.apps.googleusercontent.com`.
5. Build and run Tern, then connect your Google account.

`Config/Base.xcconfig` derives both the full client ID and the reversed redirect scheme from that prefix. Keep the client configuration and signing values in the ignored `Secrets.xcconfig`; do not edit the generated `Info.plist` to insert them.

The required mail grant is `gmail.modify` with identity scopes. New sign-ins also request optional Contacts access. Other features request their permissions when enabled in **Settings → Accounts → Connections**. See [GoogleScopes.swift](../Packages/Core/Sources/GmailAPI/GoogleScopes.swift) for the exact scopes, including the broader mail access needed for Inbox Updates and permanent deletion. Enable the corresponding APIs and scopes in the same Cloud project.

Google's testing and verification rules apply to the OAuth project independently of this repository's visibility. See [Google's installed-app OAuth guide](https://developers.google.com/identity/protocols/oauth2/native-app) for consent, access, and verification requirements.

## Build and test

Run these commands from the repository root:

```sh
# Build the app.
xcodebuild -project Tern.xcodeproj -scheme Tern \
  -configuration Debug -derivedDataPath build build

# Run hosted app tests and UI tests.
xcodebuild -project Tern.xcodeproj -scheme Tern \
  -configuration Debug -derivedDataPath build test

# Run Core tests last to restore package-only dependency pins.
swift test --package-path Packages/Core
```

The shared test scheme passes `--ui-audit` to use synthetic account data. UI tests need a logged-in macOS desktop and the system permissions requested by Xcode. These tests do not establish that live Google or ChatGPT authorization works for your configuration.

Xcode adds the app's AppAuth dependency to `Packages/Core/Package.resolved`; SwiftPM removes it again. Commit that file as `swift test` leaves it. Build products live under the ignored `build/` directory.

To build a universal Release for Apple silicon and Intel:

```sh
xcodebuild -project Tern.xcodeproj -scheme Tern \
  -configuration Release -derivedDataPath build \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  TERN_BUILD_REVISION="$(git rev-parse HEAD)" build
```

This produces a local app build. Distribution signing and notarization are separate steps.

## Screenshots

On a logged-in, unlocked Mac, run:

```sh
python3 scripts/capture-readme-screenshots.py
```

The script builds a Debug test app and captures its native window with fictional, in-memory mail and calendar services. It uses no live accounts and needs no Google or ChatGPT credentials; a blank local configuration works.

The three images are written to `docs/screenshots/`. Build logs and capture results stay in `build/readme-demo/`. Review the images before committing them. Use `--skip-build` only when that directory already contains a current test build.

## Signing

Local builds default to ad-hoc signing. To keep a consistent signing identity and avoid repeated Keychain approvals after rebuilding, set both values in `Config/Secrets.xcconfig` to an installed certificate and its team:

```xcconfig
TERN_CODE_SIGN_IDENTITY = Developer ID Application: Your Name (TEAMID)
TERN_DEVELOPMENT_TEAM = TEAMID
```

The app and hosted tests use these values in Debug and Release. A team ID alone does not replace ad-hoc signing. When switching identities, macOS may ask you to approve access to existing saved connections.

UI tests may require a configured certificate and team on macOS systems that enforce library validation. If `TernUITests` reports different Team IDs for its runner and test bundle, set both matching signing values above and rebuild the test products before retrying.

## Source layout

| Path | Responsibility |
|---|---|
| `App/` | SwiftUI and AppKit interface, Google authentication, Keychain access, and macOS integration. |
| `Packages/Core/Sources/GmailAPI/` | Google mail, calendar, tasks, and contacts clients and models. |
| `Packages/Core/Sources/MailStore/` | GRDB-backed persistence, queries, and migrations. |
| `Packages/Core/Sources/MessageContent/` | MIME extraction, HTML sanitizing, and message rendering. |
| `Packages/Core/Sources/SyncEngine/` | Mail synchronization, queued actions, attachment indexing, and local classification. |
| `Packages/Core/Sources/TernAI/` | ChatGPT authentication, model discovery, streaming, and tool contracts. |
| `Tests/` | Hosted app tests, native visual audits, and UI tests. |
| `project.yml` | XcodeGen project specification. |
| `Config/` | Shared build settings and a blank local-configuration template. |

Read [CLAUDE.md](../CLAUDE.md) before making changes. Keep tests and screenshots synthetic, avoid logging addresses or message content, and route Gmail state changes through the synchronization action queue.
