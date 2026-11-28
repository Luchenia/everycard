#!/bin/sh
# Runs the pinned Godot 4.7.2 (see engine.lock.json). Downloads it on first use.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime="$project_dir/tools/runtime"
godot_bin=${EVERYCARD_GODOT_BIN:-"$runtime/Godot_v4.7.2-stable_linux.x86_64"}
if [ ! -x "$godot_bin" ]; then
  mkdir -p "$runtime"
  url="https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip"
  curl -sSL -o "$runtime/godot.zip" "$url"
  want=$(sed -n 's/.*"archive_sha256": *"\([0-9a-f]*\)".*/\1/p' "$project_dir/engine.lock.json")
  got=$(sha256sum "$runtime/godot.zip" | cut -d' ' -f1)
  [ "$want" = "$got" ] || { echo "Godot checksum mismatch" >&2; exit 2; }
  (cd "$runtime" && unzip -q -o godot.zip && rm godot.zip)
fi
if [ "${1:-}" = "--templates" ]; then
  tdir="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/4.7.2.stable"
  if [ ! -f "$tdir/web_nothreads_release.zip" ]; then
    mkdir -p "$tdir"
    curl -sSL -o "$runtime/tpl.tpz" "https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz"
    (cd "$runtime" && unzip -q -o tpl.tpz && cp templates/* "$tdir/" && rm -rf templates tpl.tpz)
  fi
  exit 0
fi
exec "$godot_bin" --path "$project_dir" "$@"
