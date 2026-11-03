# Tern

Tern is a native macOS mail and calendar app with Gmail integration, a ChatGPT assistant, an attachment library, and account-specific settings.

[Organize Mail](docs/mail-organization.md) suggests personalized labels from the latest 250 received and sent messages. Review the categories in Settings, then apply labels and optional sender filters directly to Gmail.

The [design-token guide](docs/design/README.md) documents the app's components, shared values, native appearance rules, and refinement backlog. Open the [searchable design catalog](docs/design/catalog.html) locally to inspect token definitions and their source uses.

The canonical source is `/Users/developer/GitHub/REA_Mime` on `main`, with [TernMail on GitHub](https://github.com/salexandr0s/TernMail) as `origin`. Development branches and validation snapshots are retained in main's history. The old branches and worktrees were removed on 2026-11-02.

The installed app is `/Users/developer/Applications/Tern.app`. The universal Release build includes the performance and Contacts work alongside the current interface, onboarding, assistant, and concurrency fixes. `build/Tern-build-info.json` records its source revision, executable hash, and signing verification.

## Development

Read [CLAUDE.md](CLAUDE.md) for project conventions and local OAuth setup. Build and test from this checkout:

```sh
xcodegen generate
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build test
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Release -derivedDataPath build ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO TERN_BUILD_REVISION="$(git rev-parse HEAD)" build
swift test --package-path Packages/Core
```

Run SwiftPM after Xcode checks to leave `Packages/Core/Package.resolved` with package-only dependencies. Xcode creates development build products under `build/`; the installed app above is the copy to use normally.

For persistent Keychain approvals, set both signing values in the ignored `Config/Secrets.xcconfig` to an installed certificate and its team:

```xcconfig
TERN_CODE_SIGN_IDENTITY = Developer ID Application: Your Name (TEAMID)
TERN_DEVELOPMENT_TEAM = TEAMID
```

The app and hosted tests use that identity in both Debug and Release. Without these values, builds use ad-hoc signing, which can require fresh Keychain approval after a rebuild. When first switching to certificate signing, macOS may ask for **Always Allow** approval for each existing saved connection. Keep the signing identity consistent for subsequent builds to retain those approvals.

See [SESSION_HANDOFF.md](SESSION_HANDOFF.md) for consolidation verification and test limitations. Keep `Config/Secrets.xcconfig`, the macOS Keychain, and Tern's account data when cleaning build products.
