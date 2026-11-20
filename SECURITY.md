# Security policy

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's **private vulnerability reporting**: on this repository's **Security** tab, choose **Report a vulnerability**. You'll get an answer within a week, and a fix is released as soon as it's ready, with credit to you if you want it.

## Supported versions

Only the latest release gets security fixes.

## How Castnet protects you

- **Browser ↔ app bridge**: the extension talks to the app through the browser's native messaging and a Unix socket readable only by your user account (mode 0600). Web pages can't reach it. Safari's sandboxed extension uses a loopback connection that requires a random token stored in a file only your account can read.
- **Cookies and headers** the extension passes to the app are used only for the download they belong to and are never sent anywhere else.
- **Downloaded files** get macOS's quarantine flag, so Gatekeeper checks apps, installers and disk images before they first open.
- **Bundled tools** run as separate processes. The site-support component (yt-dlp) updates itself only from yt-dlp's official GitHub releases, and only after its SHA-256 checksum matches the published one.
