#!/usr/bin/env bash
# Renders every docs/diagrams/<name>.tex (but the preamble) to
# docs/src/diagrams/<name>.svg, the path the pages link. Run inside
# `nix develop`, which pins LaTeX, CircuiTikZ and dvisvgm.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/../src/diagrams}
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$here"
for tex in *.tex; do
  [ "$tex" = preamble.tex ] && continue
  name=${tex%.tex}
  if ! latex -interaction=nonstopmode -halt-on-error -output-directory="$tmp" "$tex" > "$tmp/$name.out" 2>&1; then
    cat "$tmp/$name.out" >&2
    echo "render.sh: $tex failed" >&2
    exit 1
  fi
  dvisvgm --no-fonts --exact-bbox --output="$out/$name.svg" "$tmp/$name.dvi" > /dev/null 2>&1
done
