#!/bin/bash
# Builds a small, LGPL-only ffmpeg + ffprobe for Castnet (stream copy only: merge, remux,
# HLS/DASH joining). Universal (arm64 + x86_64), static, depends only on macOS frameworks.
#   scripts/build-ffmpeg.sh <ffmpeg-source-dir> <output-dir>
set -euo pipefail
SRC="$(cd "$1" && pwd)"
OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
JOBS=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=13.0

COMMON=(
  --disable-everything --disable-doc --disable-debug --disable-autodetect
  --disable-ffplay --enable-ffmpeg --enable-ffprobe
  --enable-small --enable-zlib --enable-securetransport --enable-network
  --enable-protocol=file,pipe,http,https,tcp,tls,crypto,hls,data,concat
  --enable-demuxer=mov,mpegts,matroska,aac,mp3,flac,ogg,wav,hls,concat,flv,h264,hevc,ac3,eac3,data,mpegtsraw,webvtt,ass,srt
  --enable-muxer=mp4,mov,ipod,matroska,webm,mpegts,adts,mp3,flac,ogg,opus,wav,null,webvtt,srt,ass,ffmetadata
  --enable-parser=aac,aac_latm,h264,hevc,vp8,vp9,av1,opus,vorbis,mpegaudio,ac3,flac
  --enable-decoder=aac,aac_latm,mp3,mp3float,opus,vorbis,flac,ac3,eac3,pcm_s16le,webvtt,srt,ass,subrip,mov_text
  --enable-encoder=webvtt,srt,ass,subrip,mov_text
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,vp9_superframe,vp9_superframe_split,av1_frame_merge,av1_frame_split,null,dump_extradata
  --enable-filter=null,anull,aresample,format,aformat
)

for ARCH in arm64 x86_64; do
  B="$OUT/build-$ARCH"
  rm -rf "$B"; mkdir -p "$B"
  (
    cd "$B"
    EXTRA=()
    if [ "$ARCH" != "$(uname -m)" ]; then
      EXTRA=(--enable-cross-compile --arch="$ARCH" --target-os=darwin)
    fi
    if [ "$ARCH" = "x86_64" ]; then
      EXTRA+=(--disable-x86asm)  # stream copy only: no codec assembly needed
    fi
    "$SRC/configure" "${COMMON[@]}" ${EXTRA[@]+"${EXTRA[@]}"} \
      --cc="clang -arch $ARCH" --extra-cflags="-mmacosx-version-min=13.0" --extra-ldflags="-mmacosx-version-min=13.0 -arch $ARCH" \
      > configure.log 2>&1 || { tail -30 configure.log; exit 1; }
    make -j"$JOBS" ffmpeg ffprobe > make.log 2>&1 || { tail -30 make.log; exit 1; }
  )
  echo "built $ARCH"
done

for exe in ffmpeg ffprobe; do
  lipo -create "$OUT/build-arm64/$exe" "$OUT/build-x86_64/$exe" -output "$OUT/$exe"
  strip "$OUT/$exe"
done
cp "$SRC/COPYING.LGPLv2.1" "$OUT/LICENSE-ffmpeg.txt"
"$OUT/ffmpeg" -hide_banner -buildconf > "$OUT/ffmpeg-buildconf.txt" 2>&1 || true
ls -la "$OUT/ffmpeg" "$OUT/ffprobe"
otool -L "$OUT/build-arm64/ffmpeg" | sed 1d
