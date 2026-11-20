# Changelog

All notable changes to Castnet. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [1.5.5] - 2026-11-20

### Added
- **Updates inside the app.** When a new version is published, Castnet shows what's new and offers **Download & Install**. It downloads the update itself, checks it against the published SHA-256 checksum and its signature, replaces the app and reopens. Your download list, settings and downloaded files stay exactly as they are, and downloads in progress continue after the update. **Later** and **Skip This Version** are there too, and *Check for Updates…* in the Castnet menu checks right away. (This works from 1.5.5 on; earlier versions show a banner with a download link.)

### Fixed
- **Downloads from learning sites such as Canvas could end up as empty (0-byte) files** in 1.5.3–1.5.4. Their download links work only once, and Castnet paused the browser's download while it checked the link, which used the link up. Now the browser's download is never paused or touched: it's dropped only after Castnet has really received data from the link, and if Castnet can't get any, the browser finishes and Castnet takes the finished file.
- An empty answer from a server ("200 OK" with no data) is an error, never a finished download, and an empty file is never taken from the browser.
- A click on a PDF link uses the link only once (Castnet's download), so one-time PDF links work.
- When Castnet is stopped with a "terminate" signal (scripts, some shutdowns), it saves its list and pauses downloads like a normal quit.

## [1.5.4] - 2026-11-20

### Added
- **Files the browser had to download itself now end up in Castnet too.** When only the browser can fetch a download (a one-time link, a file the page made, a form download, or one that finished before the browser reported it, which happens with small files in Firefox and Zen), the browser finishes it and Castnet takes the finished file into its list and folder. No second download, no second copy.
- **PDF links go to Castnet.** A click on a link to a PDF downloads it with Castnet instead of opening the browser's viewer (⌥ Option-click opens it as before). If Castnet can't fetch it, the browser opens it.
- The app shows when a browser runs an older version of the extension, with a button to update it.

### Changed
- The "only these file types" list includes PDF and office documents, and the popup shows it only when "Every file type" is off.

## [1.5.3] - 2026-11-20

### Changed
- **Every download goes to Castnet.** The extension now takes over all downloads the browser starts, of any file type and size, instead of a list of types above 512 KB. Settings → "Every file type" can switch back to a list.
- If Castnet isn't running when a download starts, it's started, instead of the browser keeping the download.

### Added
- Before the browser's copy of a download is dropped, Castnet checks it can fetch the same file (the server answers with it, not an error or a login page, and the size matches). If not, the browser keeps the download, so one-time links and downloads that need the browser itself are never lost.

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

[1.5.5]: https://github.com/AliKotb1/Castnet/releases/tag/v1.5.5
[1.5.4]: https://github.com/AliKotb1/Castnet/releases/tag/v1.5.4
[1.5.3]: https://github.com/AliKotb1/Castnet/releases/tag/v1.5.3
[1.5.2]: https://github.com/AliKotb1/Castnet/releases/tag/v1.5.2
[1.5.1]: https://github.com/AliKotb1/Castnet/releases/tag/v1.5.1
[1.5.0]: https://github.com/AliKotb1/Castnet/releases/tag/v1.5.0
