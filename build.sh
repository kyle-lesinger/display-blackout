#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

BIN="display-blackout"

swiftc DisplayBlackout.swift -o "$BIN"

# codesign refuses to sign over Finder/Downloads extended attributes.
xattr -c "$BIN" 2>/dev/null || true

# Ad-hoc sign only to keep Gatekeeper quiet — no entitlements are needed.
codesign --force --sign - "$BIN"

echo "Built ./$BIN"
