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
  cp "$out"/*.ttf "$HOME/Library/Fonts/"
  echo "Installed to ~/Library/Fonts. Restart your editor/terminal to pick it up."
fi
