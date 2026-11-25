#!/bin/sh
# Imports the project, then runs every tests/sim/*_test.gd. Exit code = failures > 0.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
timeout 120 "$project_dir/tools/run.sh" --headless --editor --import --quit >/dev/null 2>&1 || true
exec timeout 300 "$project_dir/tools/run.sh" --headless --script res://tests/run_all.gd -- "$@"
