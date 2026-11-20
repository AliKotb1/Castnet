# Changelog

All notable changes to Castnet. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [1.5.2] - 2026-11-20

### Changed
- The browser extension builds its panel and icons as DOM elements instead of HTML strings (as addons.mozilla.org asks).
- The Firefox add-on needs Firefox 140 or later (and Firefox-based browsers built on it), which can show that Castnet collects no data.

## [1.5.1] - 2026-11-20

### Added
- A step-by-step walkthrough for adding the extension to Chrome, Edge, Brave, Arc, Vivaldi and Opera: one step at a time, with a drawing of the browser's Extensions page that highlights what to click. It moves on by itself as soon as the browser has loaded Castnet.
- The setup window shows which of your browsers already have Castnet (a green check on each).

## [1.5.0] - 2026-11-20

First public release. Versions up to 1.4.0 were private builds named *Grabber*; on first launch, Castnet moves their download list, settings and unfinished downloads over by itself.

### Browser extension
- Chrome, Edge, Brave, Arc, Vivaldi, Opera and Chromium (Manifest V3), Firefox, Zen, LibreWolf, Floorp and Waterfox, and Safari (built into the app).
- A **Download this video** panel on any playing video, with every quality, format and size; **×** hides it until the page is reloaded.
- Finds media from network responses, `fetch`/XHR bodies, `<video>` tags, `og:video` and inline JSON; HLS and DASH manifests are read for their qualities.
- Separate video-only and audio-only files are recognized from their headers (MP4, WebM) and offered as **one** choice that's merged after downloading.
- YouTube, Vimeo, X, TikTok, Instagram, Facebook and 30+ other sites list every quality, even ones not played yet.
- Right-click menu items, a link picker for *Download all/selected links*, takeover of normal browser downloads (⌥-click keeps one in the browser), and an on/off switch per site.

### Mac app
- Up to **32 connections** per file with dynamic segmentation; each connection is a separate connection to the server.
- **Expired links are renewed automatically**: Castnet gets a fresh link through the browser, checks it's the same file and continues from the byte where it stopped. Network outages are waited out.
- HLS (AES-128, fMP4, separate audio, live recording) and DASH; video and audio merged without re-encoding.
- Toolbar, categories, queues, columns, *Download File Info*, *download status* (segment map, connections), *download complete* (Open, Open With…, Open Folder) and *duplicate link* windows.
- Multiple queues with a scheduler: start and stop times, days, files at the same time, order, and when done: quit, sleep or shut down (with a countdown you can cancel).
- Batch download (`*` patterns, lists, clipboard), import and export of links, clipboard monitoring (optional), speed limiter (total and per download).
- Finished files get macOS's quarantine flag like browser downloads, so Gatekeeper checks downloaded apps and disk images.
- Fully self-contained: yt-dlp, FFmpeg and QuickJS are inside the app; nothing to install with Terminal or Homebrew. Universal (Apple Silicon and Intel), macOS 13 or later.

[1.5.2]: https://github.com/AliKotb1/Castnet/releases/tag/v1.5.2
[1.5.1]: https://github.com/AliKotb1/Castnet/releases/tag/v1.5.1
[1.5.0]: https://github.com/AliKotb1/Castnet/releases/tag/v1.5.0
