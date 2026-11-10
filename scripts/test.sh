#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Standalone Command Line Tools bundle Swift Testing outside SwiftPM's search paths.
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == */CommandLineTools ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  runtime="$developer_dir/Library/Developer/usr/lib"
  exec swift test --disable-xctest \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xlinker -F -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$runtime" "$@"
fi

exec swift test "$@"
