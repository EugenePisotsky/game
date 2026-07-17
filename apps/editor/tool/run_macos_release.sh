#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
exec flutter run -d macos --release --no-tree-shake-icons "$@"
