#!/usr/bin/env bash
# Generate tiny local fixtures for smoke tests. Nothing is downloaded.
# Output: fixtures/out/src (gitignored). Needs ffmpeg + magick (Homebrew), textutil/sips/cupsfilter (macOS).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=fixtures/out/src
rm -rf "$OUT"
mkdir -p "$OUT"
FF="ffmpeg -hide_banner -loglevel error -y"

echo "images…"
magick -size 160x120 gradient:steelblue-orange -fill white -draw "circle 80,60 80,25" "$OUT/sample.png"
magick "$OUT/sample.png" -quality 90 "$OUT/sample.jpg"
magick "$OUT/sample.png" "$OUT/sample.webp"
magick "$OUT/sample.png" "$OUT/sample.avif"
magick "$OUT/sample.png" "$OUT/sample.tiff"
magick "$OUT/sample.png" "$OUT/sample.bmp"
magick "$OUT/sample.png" "$OUT/sample.gif"
sips -s format heic "$OUT/sample.png" --out "$OUT/sample.heic" >/dev/null
magick -size 160x120 xc:white -fill seagreen -draw "rectangle 20,20 140,100" "$OUT/second.png"
cat > "$OUT/sample.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="160" height="120" viewBox="0 0 160 120">
  <rect width="160" height="120" fill="#2b6cb0"/><circle cx="80" cy="60" r="35" fill="#f6ad55"/>
</svg>
EOF

echo "video…"
SRC_V=(-f lavfi -i "testsrc=size=160x120:rate=15" -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 2)
$FF "${SRC_V[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/sample.mp4"
$FF "${SRC_V[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/sample.mov"
$FF "${SRC_V[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/sample.mkv"
$FF "${SRC_V[@]}" -c:v libvpx-vp9 -b:v 200k -c:a libopus -shortest "$OUT/sample.webm"
$FF "${SRC_V[@]}" -c:v mpeg4 -c:a libmp3lame -shortest "$OUT/sample.avi"
$FF "${SRC_V[@]}" -c:v wmv2 -c:a wmav2 -shortest "$OUT/sample.wmv"
$FF "${SRC_V[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/sample.m4v"
$FF -f lavfi -i "testsrc2=size=160x120:rate=15" -f lavfi -i "sine=frequency=660" -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/second.mp4"

echo "audio…"
SRC_A=(-f lavfi -i "sine=frequency=440:sample_rate=44100" -t 2)
$FF "${SRC_A[@]}" -c:a libmp3lame "$OUT/sample.mp3"
$FF "${SRC_A[@]}" -c:a aac "$OUT/sample.m4a"
$FF "${SRC_A[@]}" "$OUT/sample.wav"
$FF "${SRC_A[@]}" -c:a flac "$OUT/sample.flac"
$FF "${SRC_A[@]}" -ac 2 -c:a vorbis -strict -2 "$OUT/sample.ogg"
$FF "${SRC_A[@]}" -c:a libopus "$OUT/sample.opus"
$FF "${SRC_A[@]}" "$OUT/sample.aiff"
$FF "${SRC_A[@]}" -c:a wmav2 "$OUT/sample.wma"

echo "documents…"
{
  echo "Rondo fixture document"
  echo
  for i in $(seq 1 90); do echo "Line $i: The quick brown fox jumps over the lazy dog."; done
} > "$OUT/sample.txt"
/usr/sbin/cupsfilter "$OUT/sample.txt" > "$OUT/sample.pdf" 2>/dev/null
magick "$OUT/sample.png" "$OUT/second.png" "$OUT/images.pdf"
for f in docx rtf html odt doc; do textutil -convert "$f" "$OUT/sample.txt" -output "$OUT/sample.$f"; done
cat > "$OUT/sample.md" <<'EOF'
# Fixture

Some **bold** and *italic* text with a [link](https://example.com).

- one
- two
EOF

echo "subtitles…"
cat > "$OUT/sample.srt" <<'EOF'
1
00:00:00,000 --> 00:00:01,000
Hello there.

2
00:00:01,000 --> 00:00:02,000
<i>General</i> fixture.
EOF
cat > "$OUT/sample.vtt" <<'EOF'
WEBVTT

00:00:00.000 --> 00:00:01.000
Hello there.

00:00:01.000 --> 00:00:02.000
Second cue.
EOF

echo "spreadsheets…"
printf 'name,qty,note\nApple,3,"red, sweet"\nPear,5,"says ""hi"""\n' > "$OUT/sample.csv"
printf 'name\tqty\nApple\t3\nPear\t5\n' > "$OUT/sample.tsv"

echo "archives…"
mkdir -p "$OUT/sample-folder"
cp "$OUT/sample.txt" "$OUT/sample.png" "$OUT/sample-folder/"
(cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent sample-folder sample.zip)
(cd "$OUT" && tar -cf sample.tar sample-folder && tar -czf sample.tar.gz sample-folder)
gzip -kc "$OUT/sample.txt" > "$OUT/sample.txt.gz"

echo "Fixtures in $OUT: $(ls "$OUT" | wc -l | tr -d ' ') entries, $(du -sh "$OUT" | cut -f1)"
