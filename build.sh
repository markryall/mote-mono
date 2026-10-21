#!/usr/bin/env bash
# Build Mote Mono from private-build-plans.toml and optionally install it.
#   ./build.sh            build unhinted TTFs into tmp/iosevka/dist/MoteMono
#   ./build.sh --install  ...and copy them into ~/Library/Fonts
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
src="$root/tmp/iosevka"
plan="MoteMono"

if [[ ! -d "$src" ]]; then
  git clone --depth 1 https://github.com/be5invis/Iosevka.git "$src"
fi

cp "$root/private-build-plans.toml" "$src/private-build-plans.toml"

# Round curves like Spot's: superness 2 is a true ellipse, Iosevka's default 2.275 is
# squarer. It isn't a build-plan option, so patch the source (idempotent).
aesthetics="$src/packages/font-glyphs/src/meta/aesthetics.ptl"
sed -i '' -E 's/^(	superness +)[0-9.]+$/\12.0/' "$aesthetics"
grep -qE '^	superness +2\.0$' "$aesthetics" || { echo "superness patch failed: Iosevka source moved" >&2; exit 1; }

cd "$src"
[[ -d node_modules ]] || npm ci
# Unhinted is fine on macOS; hinting needs ttfautohint and only matters on Windows.
npm run build -- "ttf-unhinted::$plan"

out="$src/dist/$plan/TTF-Unhinted"
echo "Built: $out"
ls "$out"

if command -v hb-view >/dev/null; then
  hb-view --font-size=28 --margin=24 --background=#1e1e2e --foreground=#cdd6f4 \
    -o "$root/tmp/specimen.png" "$out/$plan-Regular.ttf" --text-file="$root/specimen.txt"
  echo "Preview: $root/tmp/specimen.png"
fi

if [[ "${1:-}" == "--install" ]]; then
  # Copy then rename, never overwrite in place: running apps mmap the installed
  # fonts, and truncating a mapped file segfaults them (WezTerm died in FreeType).
  for f in "$out"/*.ttf; do
    dest="$HOME/Library/Fonts/$(basename "$f")"
    cp "$f" "$dest.tmp" && mv -f "$dest.tmp" "$dest"
  done
  echo "Installed to ~/Library/Fonts. Restart your editor/terminal to pick it up."
fi
