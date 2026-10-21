#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift run --package-path "$project_dir" --scratch-path "${RELAY_BUILD_DIR:-$project_dir/.build}" --configuration debug RelayChecks
