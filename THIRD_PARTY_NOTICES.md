# Third-party software

Castnet's own code is under the [MIT License](LICENSE). The Mac app bundles three separate programs, each run as its own process and each under its own license. The license texts ship inside the app at `Castnet.app/Contents/Resources/Licenses/`.

| Component | Version | License | Source | Used for |
|---|---|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | 2026.10.26 (official `yt-dlp_macos` build) | [Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE) | [github.com/yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp) | Quality lists and downloads for video sites. Updates itself to newer official releases (checksums verified) in `~/Library/Application Support/Castnet/bin` |
| [FFmpeg](https://ffmpeg.org) | 9.0.2 | [LGPL 2.1 or later](https://ffmpeg.org/legal.html) | The exact, unmodified source is attached to every [release](https://github.com/AliKotb1/Castnet/releases) as `ffmpeg-9.0.2.tar.xz`; the build script is [`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh) | Merging video and audio, TS → MP4 (stream copy only) |
| [QuickJS](https://bellard.org/quickjs/) | 2026-06-04 | [MIT](https://bellard.org/quickjs/) | [bellard.org/quickjs](https://bellard.org/quickjs/) | Running the JavaScript challenges some video sites send |

## FFmpeg

The bundled `ffmpeg` and `ffprobe` are a minimal LGPL build: no GPL or non-free parts are enabled. The exact `configure` options are in `Castnet.app/Contents/Resources/Licenses/ffmpeg-build-configuration.txt`, and [`scripts/fetch-vendor.sh`](scripts/fetch-vendor.sh) rebuilds them from the official tarball. FFmpeg is a separate program that Castnet runs. It isn't linked into Castnet, so you can replace `Castnet.app/Contents/Helpers/ffmpeg` with your own build.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
