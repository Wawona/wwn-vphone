#!/usr/bin/env bash
# Copy Wawona accessibility_tree sources into a vphone-cli checkout and
# patch Makefile + entitlements so CFW / host auto-update ships AX.
set -euo pipefail

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-${VPHONE_CLI_SRC:-${VPHONE_ROOT:-$HOME/.vphone}/src/vphone-cli}}"
VPHONED="$SRC/scripts/vphoned"

if [[ -f "$SRC/VPhoneDaemon/Native/vphoned_ax_hierarchy.m" || ! -d "$VPHONED" ]]; then
  echo "apply-vphoned-ax: vphone 2.x serves ui.tree; 1.x overlay not applied"
  exit 0
fi

cp "$PATCH_DIR/vphoned_accessibility.h" "$VPHONED/vphoned_accessibility.h"
cp "$PATCH_DIR/vphoned_accessibility.c" "$VPHONED/vphoned_accessibility.c"

MAKEFILE="$VPHONED/Makefile"
if [[ -f "$MAKEFILE" ]] && ! grep -q 'framework CoreGraphics' "$MAKEFILE"; then
  if grep -q -- '-framework CoreServices' "$MAKEFILE"; then
    /usr/bin/sed -i '' \
      's/-framework CoreServices/-framework CoreServices \\\
		-framework CoreGraphics \\\
		-weak_framework UIKit/' \
      "$MAKEFILE"
  fi
fi

ENTS="$VPHONED/entitlements.plist"
if [[ -f "$ENTS" && -x /usr/libexec/PlistBuddy ]]; then
  merge_bool() {
    local key="$1"
    if /usr/libexec/PlistBuddy -c "Print :$key" "$ENTS" >/dev/null 2>&1; then
      return 0
    fi
    /usr/libexec/PlistBuddy -c "Add :$key bool true" "$ENTS"
  }
  merge_bool 'com.apple.accessibility.api'
  merge_bool 'com.apple.private.accessibility.application-browsing'
  merge_bool 'com.apple.private.accessibility.scanner'
  merge_bool 'com.apple.private.accessibility.can-gestures'
fi

echo "apply-vphoned-ax: patched $VPHONED"
