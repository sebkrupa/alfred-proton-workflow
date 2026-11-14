#!/bin/bash
# Generate a password via pass-cli and copy it to the clipboard.
# Optional first argument: length (default 20).

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
source "$(dirname "$0")/lib.sh"

length="${1:-20}"
# Allow plain numeric input; ignore anything weird.
if ! [[ "$length" =~ ^[0-9]+$ ]]; then
  length=20
fi

if value="$(pass-cli password generate random --length "$length" 2>&1)"; then
  copy_transient "$value"
  notify "Proton Pass" "Generated ${length}-char password copied (clears in ${CLIP_CLEAR_SECONDS}s)"
else
  notify "Proton Pass" "Failed: $value"
  exit 1
fi
