#!/bin/bash
# Shared helpers for action.sh and generate.sh. Source, don't execute.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only digits are accepted: bash arithmetic on an unchecked variable can run
# command substitutions (e.g. `a[$(cmd)]`).
CLIP_CLEAR_SECONDS="${PP_CLIP_CLEAR:-45}"
[[ "$CLIP_CLEAR_SECONDS" =~ ^[0-9]+$ ]] || CLIP_CLEAR_SECONDS=45

# Text goes to AppleScript as argv, never spliced into the script source, so
# item titles/notes/errors cannot inject AppleScript (`do shell script`).
notify() {
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' \
    -- "$1" "$2" >/dev/null 2>&1 || true
}

dialog() {
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK"' \
    -e 'end run' \
    -- "$1" "$2" >/dev/null 2>&1 || true
}

# Copy $1 (via stdin) as a concealed, this-Mac-only clipboard item and clear it
# after $CLIP_CLEAR_SECONDS unless something else was copied in the meantime.
copy_transient() {
  local count
  count="$(printf '%s' "$1" | /usr/bin/osascript -l JavaScript "$LIB_DIR/clip.js" copy)"
  if (( CLIP_CLEAR_SECONDS > 0 )) && [[ "$count" =~ ^[0-9]+$ ]]; then
    (
      sleep "$CLIP_CLEAR_SECONDS"
      /usr/bin/osascript -l JavaScript "$LIB_DIR/clip.js" clear "$count"
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}
