#!/usr/bin/env bash
# Fetch and transcode the audio the built-in 演出 (Preset Live) timelines are
# timed to, for LOCAL USE ONLY.
#
# These recordings are commercial Love Live! tracks (the Nijigasaki soundtrack,
# Tennoji Rina's character songs, and Kasumi Nakasu's "Poppin' Up!"). Both
# upstream projects ship them with no licence grant, and neither this script
# nor the app redistributes them: the files land in a .gitignore'd path, are
# never committed, and are only present in a local build. The keyframe
# timelines in Resources/performance_*.rinalive are a different matter — they
# are upstream's own AGPL/GPL-licensed work and are tracked in this repo.
#
# The Xcode project uses a synchronized file group, so a clone without these
# files still builds; the 演出 tab simply marks those performances as having
# no audio.
#
# Ogg Vorbis will not play on iOS, so the .ogg files are transcoded to AAC in
# an M4A container with `afconvert` (macOS CoreAudio decodes Vorbis; iOS does
# not). The transcode is verified to introduce **zero** timing shift — see
# tools/verify_preset_live_alignment.py, which cross-correlates the decoded
# original against the decoded transcode and must report a 0-sample lag, since
# a shift of even a fraction of a keyframe (100 ms at 10 fps) would desync the
# board from the music.
#
# Usage:  ./tools/fetch_preset_live_audio.sh [--keep-intermediate]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$REPO_ROOT/ios/RinaBoard/Resources"
WORK="$REPO_ROOT/build/preset_live_audio"
KEEP=0
[[ "${1:-}" == "--keep-intermediate" ]] && KEEP=1

NGX_BASE="https://raw.githubusercontent.com/738NGX/RinaChanBoard/main/RinaChanBoardOperationCenter/Assets/Resources/Music"
AKARI_MP3="https://raw.githubusercontent.com/flyAkari/RinaChanBoard/main/Android/RinaChanBoardController/app/src/main/res/raw/poppin_up.mp3"
COVERS=(tkmk lumf solo0 solo1 solo2 solo3 solo4 solo5)

command -v afconvert >/dev/null || { echo "afconvert not found (macOS only)" >&2; exit 1; }

mkdir -p "$WORK" "$RESOURCES"

echo "Fetching Ogg Vorbis sources from 738NGX/RinaChanBoard…"
for cover in "${COVERS[@]}"; do
    if [[ ! -f "$WORK/music_$cover.ogg" ]]; then
        curl -fsSL "$NGX_BASE/music_$cover.ogg" -o "$WORK/music_$cover.ogg"
    fi
    echo "  music_$cover.ogg"
done

echo "Transcoding to AAC/M4A (iOS cannot decode Vorbis)…"
for cover in "${COVERS[@]}"; do
    afconvert -f m4af -d aac -b 192000 "$WORK/music_$cover.ogg" "$RESOURCES/audio_$cover.m4a"
    echo "  audio_$cover.m4a"
done

echo "Fetching MP3 from flyAkari/RinaChanBoard…"
# Already MP3, which iOS plays natively — copied verbatim, no re-encode, so
# there is nothing to verify for this one.
curl -fsSL "$AKARI_MP3" -o "$RESOURCES/audio_poppin_up.mp3"
echo "  audio_poppin_up.mp3"

if [[ $KEEP -eq 0 ]]; then
    rm -rf "$WORK"
else
    echo "Kept intermediate Ogg files in $WORK (needed by verify_preset_live_alignment.py)"
fi

echo
echo "Done. These files are .gitignore'd — do not commit them."
