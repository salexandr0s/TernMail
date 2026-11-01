# Tern

Tern is a native macOS mail and calendar app with Gmail integration, a ChatGPT assistant, an attachment library, and account-specific settings.

The canonical source is `/Users/developer/GitHub/REA_Mime` on `main`. All previous milestone, design, and review branches are included in its history. The old branches and worktrees were removed on 2026-10-30.

The installed app is `/Users/developer/Applications/Tern.app`. This universal Release build includes the completed settings redesign, calendar drag editing, and the latest assistant changes. Old preview and build bundles have been removed. `build/Tern-build-info.json` records its source revision and executable hash.

## Development

Read [CLAUDE.md](CLAUDE.md) for project conventions and local OAuth setup. Build and test from this checkout:

```sh
xcodegen generate
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build test
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Release -derivedDataPath build ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
swift test --package-path Packages/Core
```

Run SwiftPM after Xcode checks to leave `Packages/Core/Package.resolved` with package-only dependencies. Xcode creates development build products under `build/`; the installed app above is the copy to use normally.

For persistent Keychain approvals, set both signing values in the ignored `Config/Secrets.xcconfig` to an installed certificate and its team:

```xcconfig
TERN_CODE_SIGN_IDENTITY = Developer ID Application: Your Name (TEAMID)
TERN_DEVELOPMENT_TEAM = TEAMID
```

The app and hosted tests use that identity in both Debug and Release. Without these values, builds use ad-hoc signing, which can require fresh Keychain approval after a rebuild. When first switching to certificate signing, macOS may ask for **Always Allow** approval for each existing saved connection. Keep the signing identity consistent for subsequent builds to retain those approvals.

See [SESSION_HANDOFF.md](SESSION_HANDOFF.md) for consolidation verification, recovery files, and remaining acceptance checks. No Git remote is configured.
