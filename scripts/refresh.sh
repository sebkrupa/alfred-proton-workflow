#!/bin/bash
# Rebuild the item index now (keyword `pprefresh`) and report the result.

set -uo pipefail

source "$(dirname "$0")/lib.sh"

"$(dirname "$0")/index.sh" --force
cache="${alfred_workflow_cache:-$(dirname "$0")/../cache}/index.json"
msg="$(/usr/bin/python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    n, errs = len(d.get("items") or []), d.get("errors") or []
    print(f"Indexed {n} items" + (f" ({len(errs)} warning(s): {errs[0][:80]})" if errs else ""))
except Exception as e:
    print(f"Refresh failed: {e}")
' "$cache")"
notify "Proton Pass" "$msg"
