#!/bin/bash
# Format (or lint) the Swift sources with the toolchain's swift-format,
# using the repo's .swift-format config. Usage:
#   Packaging/format.sh          # format in place
#   Packaging/format.sh --lint   # check only (non-zero exit if not formatted)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--lint" ]]; then
    swift format lint --strict --recursive Sources Package.swift
    echo "✓ lint clean"
else
    swift format --in-place --recursive Sources Package.swift
    echo "✓ formatted Sources + Package.swift"
fi
