#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/Sources/Ticker/Assets.xcassets/AppIcon.appiconset"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

render_bin="$tmp_dir/render_app_icon"
base_png="$tmp_dir/icon_1024.png"

swiftc -O \
  -parse-as-library \
  -module-cache-path "$tmp_dir/module-cache" \
  "$ROOT_DIR/tools/icon/render_app_icon.swift" \
  -o "$render_bin" \
  -framework AppKit
"$render_bin" "$base_png"

iconset_dir="$tmp_dir/AppIcon.iconset"
mkdir -p "$iconset_dir"

make_png() {
  local size="$1"
  local name="$2"
  /usr/bin/sips -s format png -z "$size" "$size" "$base_png" --out "$iconset_dir/$name" >/dev/null
}

make_png 16  icon_16x16.png
make_png 32  icon_16x16@2x.png
make_png 32  icon_32x32.png
make_png 64  icon_32x32@2x.png
make_png 128 icon_128x128.png
make_png 256 icon_128x128@2x.png
make_png 256 icon_256x256.png
make_png 512 icon_256x256@2x.png
make_png 512 icon_512x512.png
make_png 1024 icon_512x512@2x.png

mkdir -p "$OUT_DIR"
cp -f "$iconset_dir/"*.png "$OUT_DIR/"

echo "Wrote PNGs into: $OUT_DIR"
