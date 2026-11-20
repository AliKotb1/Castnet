# Contributing to Castnet

Thanks for helping! Bug reports, fixes, new site support and translations of the UI are all welcome.

## Reporting a bug

Open an [issue](https://github.com/AliKotb1/Castnet/issues/new/choose) with:
- your macOS version, Mac (Apple Silicon or Intel), browser and Castnet version (shown in the app's status bar);
- the page or link (if it's public) and what you expected;
- for downloads that fail, the message in the *Description* column.

Security problems go through [private reporting](SECURITY.md) instead.

## Building

You need macOS 13 or later, Xcode or the Command Line Tools (Swift 5.9+, macOS 15.4 SDK or newer) and Node.js 18+.

```bash
./scripts/fetch-vendor.sh      # once: downloads yt-dlp, builds FFmpeg and QuickJS into ./vendor
./scripts/build.sh             # → dist/Castnet.app
./scripts/make-dmg.sh          # → dist/Castnet-<version>.dmg
```

`swift build --package-path app` builds just the Swift code, and `node scripts/build-extensions.mjs` just the browser extensions. Views use `ObservableObject` instead of `@State` so the app builds with the Command Line Tools alone (they don't include SwiftUI's macro plugin).

## Testing

The tests generate their own media with FFmpeg, so for development you need a full FFmpeg (`brew install ffmpeg`). Castnet itself never uses Homebrew.

```bash
./test/run-all.sh                        # extension unit tests, engine tests, download-manager self-test
node test/e2e.mjs /tmp/castnet-e2e      # real Chrome + the extension (needs Chrome and playwright-core)
node test/e2e-renew.mjs /tmp/castnet-e2e  # a link that expires mid-download is renewed
node test/e2e-takeover.mjs /tmp/castnet-e2e  # every browser download goes to Castnet, safely
./test/dmg-test.sh dist/Castnet-<version>.dmg   # the DMG works with Homebrew hidden
```

Tests run against a separate test copy of the app (`CASTNET_HOME`, `CASTNET_HEADLESS`) and never touch your own download list.

## Pull requests

- One change per pull request, with a short description of what and why.
- Add or update tests for behaviour changes (`app/Sources/castnet-selftest`, `test/ext-unit.mjs`).
- Keep the UI text plain and short. The app must stay self-contained: no feature may require users to install anything with Terminal or Homebrew.
- Run `./test/run-all.sh` before opening the pull request; CI runs the build, the extension tests and the self-test.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
