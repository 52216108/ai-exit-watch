#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target WatchCore
module_path="$(swift build --show-bin-path)"
mkdir -p .build/readme-preview
if [[ -f "$module_path/WatchCore.o" ]]; then
  core_arguments=(-I "$module_path" "$module_path/WatchCore.o")
else
  core_arguments=(-I "$module_path/Modules" "$module_path"/WatchCore.build/*.o)
fi
swiftc -D IS_DEVTOOLS -parse-as-library "${core_arguments[@]}" \
  Sources/NetworkWatch/Dashboard.swift Sources/NetworkWatch/ExitComparisonView.swift \
  scripts/readme-preview.swift -o .build/readme-preview/render
.build/readme-preview/render docs/screenshots
