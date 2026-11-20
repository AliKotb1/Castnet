#!/bin/bash
# Downloads and builds the tools Castnet.app carries inside itself, into ./vendor:
#   vendor/bin/yt-dlp        official standalone yt-dlp_macos (universal), checksum-verified
#   vendor/bin/ffmpeg|ffprobe  minimal LGPL build (stream copy only), universal, static
#   vendor/bin/qjs           QuickJS JavaScript engine (YouTube challenges), universal
#   vendor/licenses/         license texts shipped in the app
#   vendor/src/              FFmpeg's source tarball (attached to every release)
# Needs only Xcode Command Line Tools. Run once per release (or to bump versions).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YTDLP_VERSION="${YTDLP_VERSION:-2026.10.26}"
FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
QJS_VERSION="${QJS_VERSION:-2026-06-04}"
WORK="${WORK:-$(mktemp -d -t castnet-vendor)}"
OUT="$ROOT/vendor"
mkdir -p "$OUT/bin" "$OUT/licenses" "$WORK"
export MACOSX_DEPLOYMENT_TARGET=13.0

echo "==> yt-dlp $YTDLP_VERSION"
cd "$WORK"
curl -fL --retry 5 -C - -o yt-dlp_macos "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos"
curl -fsSL -o SHA2-256SUMS "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/SHA2-256SUMS"
grep ' yt-dlp_macos$' SHA2-256SUMS | shasum -a 256 -c -
install -m 755 yt-dlp_macos "$OUT/bin/yt-dlp"
echo "$YTDLP_VERSION" > "$OUT/bin/yt-dlp.version"
curl -fsSL -o "$OUT/licenses/yt-dlp-LICENSE.txt" "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION/LICENSE"

echo "==> QuickJS $QJS_VERSION"
curl -fsSL -o qjs.tar.xz "https://bellard.org/quickjs/quickjs-$QJS_VERSION.tar.xz"
tar xf qjs.tar.xz
(
  cd "quickjs-$QJS_VERSION"
  make -j"$(sysctl -n hw.ncpu)" qjs > /dev/null   # also generates repl.c
  V=$(cat VERSION)
  for a in arm64 x86_64; do
    clang -arch $a -mmacosx-version-min=13.0 -O2 -fwrapv -flto -D_GNU_SOURCE -DCONFIG_VERSION="\"$V\"" \
      qjs.c repl.c quickjs.c dtoa.c libregexp.c libunicode.c cutils.c quickjs-libc.c -lm -o qjs-$a
  done
  lipo -create qjs-arm64 qjs-x86_64 -output "$OUT/bin/qjs"
  strip "$OUT/bin/qjs"
  cp LICENSE "$OUT/licenses/QuickJS-LICENSE.txt"
)

echo "==> ffmpeg $FFMPEG_VERSION"
curl -fsSL -o ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
tar xf ffmpeg.tar.xz
# Kept for releases: FFmpeg's license (LGPL) asks for its exact source next to the binaries.
mkdir -p "$OUT/src" && cp ffmpeg.tar.xz "$OUT/src/ffmpeg-$FFMPEG_VERSION.tar.xz"
"$ROOT/scripts/build-ffmpeg.sh" "ffmpeg-$FFMPEG_VERSION" "$WORK/ffmpeg-out"
install -m 755 "$WORK/ffmpeg-out/ffmpeg" "$WORK/ffmpeg-out/ffprobe" "$OUT/bin/"
cp "$WORK/ffmpeg-out/LICENSE-ffmpeg.txt" "$OUT/licenses/ffmpeg-LGPL-2.1.txt"
cp "$WORK/ffmpeg-out/ffmpeg-buildconf.txt" "$OUT/licenses/ffmpeg-build-configuration.txt"

echo "==> vendor ready"
ls -la "$OUT/bin"
