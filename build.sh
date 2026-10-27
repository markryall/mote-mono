#!/usr/bin/env bash
# Build Mote Mono from private-build-plans.toml and optionally install it.
#   ./build.sh            build unhinted TTFs into tmp/iosevka/dist/MoteMono
#   ./build.sh --install  ...and copy them into ~/Library/Fonts
#   ./build.sh --release  ...and publish them as a GitHub release, tagged with the plan's version,
#                         then point the font-mote-mono cask in markryall/homebrew-tap at it
set -euo pipefail

install=false release=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    --release) release=true ;;
    *) echo "usage: $0 [--install] [--release]" >&2; exit 2 ;;
  esac
done

root="$(cd "$(dirname "$0")" && pwd)"
src="$root/tmp/iosevka"
plan="MoteMono"

if [[ ! -d "$src" ]]; then
  git clone --depth 1 https://github.com/be5invis/Iosevka.git "$src"
fi

cp "$root/private-build-plans.toml" "$src/private-build-plans.toml"

# Source changes the build plan can't express live in patches/*.patch
# (make one with: git -C tmp/iosevka diff -- <files> > patches/name.patch).
# Skip a patch that's already applied; stop if one no longer fits Iosevka's source.
for p in "$root"/patches/*.patch; do
  [[ -e "$p" ]] || continue
  if git -C "$src" apply --reverse --check "$p" 2>/dev/null; then
    continue
  fi
  git -C "$src" apply "$p" || { echo "patch $(basename "$p") no longer applies to Iosevka" >&2; exit 1; }
done

cd "$src"
[[ -d node_modules ]] || npm ci
# Unhinted is fine on macOS; hinting needs ttfautohint and only matters on Windows.
npm run build -- "ttf-unhinted::$plan"

out="$src/dist/$plan/TTF-Unhinted"
echo "Built: $out"
ls "$out"

# Iosevka only draws square stroke ends; round them like Spot's (round-corners.py).
venv="$root/tmp/venv"
[[ -x "$venv/bin/python" ]] || { python3 -m venv "$venv" && "$venv/bin/pip" install -q fonttools; }
"$venv/bin/python" "$root/round-corners.py" "$out"/*.ttf

if command -v hb-view >/dev/null; then
  hb-view --font-size=28 --margin=24 --background=#1e1e2e --foreground=#cdd6f4 \
    -o "$root/tmp/specimen.png" "$out/$plan-Regular.ttf" --text-file="$root/specimen.txt"
  echo "Preview: $root/tmp/specimen.png"
fi

if $install; then
  # Copy then rename, never overwrite in place: running apps mmap the installed
  # fonts, and truncating a mapped file segfaults them (WezTerm died in FreeType).
  for f in "$out"/*.ttf; do
    dest="$HOME/Library/Fonts/$(basename "$f")"
    cp "$f" "$dest.tmp" && mv -f "$dest.tmp" "$dest"
  done
  echo "Installed to ~/Library/Fonts. Restart your editor/terminal to pick it up."
fi

if $release; then
  version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/private-build-plans.toml")"
  tag="v$version"
  # Release the commit the fonts were built from; GitHub refuses one that isn't pushed.
  commit="$(git -C "$root" rev-parse HEAD)"
  zip="$root/tmp/$plan-$version.zip"
  rm -f "$zip"
  zip -j "$zip" "$out"/*.ttf "$root/LICENSE.md"
  gh release create "$tag" "$zip" --repo markryall/mote-mono --target "$commit" \
    --title "Mote Mono $version" \
    --notes "Mote Mono $version: Light, Regular, Medium and Bold, each with an italic. Unzip and install the .ttf files; see the README for details."

  # Bump the Homebrew cask to the zip just uploaded (same bytes, so same checksum).
  tap="$root/tmp/homebrew-tap"
  cask="$tap/Casks/font-mote-mono.rb"
  if [[ -d "$tap" ]]; then
    jj -R "$tap" git fetch
    jj -R "$tap" new main@origin
  else
    jj git clone git@github.com:markryall/homebrew-tap.git "$tap"
  fi
  sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
  sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
  jj -R "$tap" describe -m "font-mote-mono $version"
  jj -R "$tap" bookmark set main -r @
  jj -R "$tap" git push -b main
fi
