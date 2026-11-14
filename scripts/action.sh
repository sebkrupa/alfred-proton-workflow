#!/bin/bash
# Dispatch an Alfred action against a Proton Pass item.
# Receives one argument: ACTION|SHARE_ID|ITEM_ID|TITLE
#
# ACTION ∈ {password, username, totp, url, details, login, card, cvv, alias, custom}

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
source "$(dirname "$0")/lib.sh"

arg="${1:-}"
IFS='|' read -r action share_id item_id title <<<"$arg"
# `--flag=value`: an ID that starts with "-" is otherwise read as a flag.
ids=(--share-id="$share_id" --item-id="$item_id")

# Put this item first in the empty-query `pp` list. IDs only, never values.
remember() {
  local dir="${alfred_workflow_cache:-$(dirname "$0")/../cache}" f
  f="$dir/recent.txt"
  [[ "$item_id" =~ ^[A-Za-z0-9_=-]+$ ]] || return 0
  (
    umask 077
    mkdir -p "$dir"
    { printf '%s\n' "$item_id"; grep -vxF -- "$item_id" "$f" 2>/dev/null | head -n 49; } >"$f.tmp" &&
      mv "$f.tmp" "$f"
  ) || true
}

# Copy one named field of the item. $1 = field, $2 = label for the notification.
# Returns 1 (no notification) when the field is missing or empty.
copy_field() {
  local value
  value="$(pass-cli item view "${ids[@]}" --field "$1" 2>/dev/null)" && [[ -n "$value" ]] || return 1
  copy_transient "$value"
  remember
  notify "Proton Pass" "$2 for $title copied (clears in ${CLIP_CLEAR_SECONDS}s)"
}

# Copy a value found in the item's JSON. $1 = alias (the alias address) or
# secret (first Hidden field, else first Text field, across custom sections
# and extra fields — e.g. an API token item without a password).
copy_from_json() {
  local json found
  json="$(pass-cli item view "${ids[@]}" --output json 2>&1)" || {
    notify "Proton Pass" "Could not read item: $json"
    return 0
  }
  # Script via -c, JSON via stdin. Prints "<label>\n<value>" or nothing.
  found="$(printf '%s' "$json" | /usr/bin/python3 -I -c '
import json, sys
try:
    item = json.load(sys.stdin)["item"]
    if sys.argv[1] == "alias":
        if item.get("alias_email"):
            print("Alias address"); print(item["alias_email"])
        sys.exit()
    c = item["content"]
    fields = []
    for sec in ((c.get("content") or {}).get("Custom") or {}).get("sections") or []:
        fields += sec.get("section_fields") or []
    fields += c.get("extra_fields") or []
    for kind in ("Hidden", "Text"):
        for f in fields:
            v = (f.get("content") or {}).get(kind)
            if v:
                print(f.get("name") or "Secret"); print(v); sys.exit()
except Exception:
    pass
' "$1")" || found=""
  if [[ -n "$found" ]]; then
    copy_transient "${found#*$'\n'}"
    remember
    notify "Proton Pass" "${found%%$'\n'*} of $title copied (clears in ${CLIP_CLEAR_SECONDS}s)"
  else
    notify "Proton Pass" "Nothing to copy on $title"
  fi
}

case "$action" in
  login)
    pass_cli_path="$(command -v pass-cli || true)"
    if [[ -z "$pass_cli_path" ]]; then
      notify "Proton Pass" "pass-cli not found in PATH"
      exit 0
    fi

    command_dir="$(mktemp -d "${TMPDIR:-/tmp}/proton-pass-login.XXXXXX")"
    command_file="$command_dir/login.command"
    quoted_pass_cli_path="$(printf '%q' "$pass_cli_path")"
    cat >"$command_file" <<SH
#!/bin/bash
command_dir="\$(dirname "\$0")"
rm -f "\$0"
rmdir "\$command_dir" 2>/dev/null || true
# logout first so this also recovers a session that reports authenticated but
# can no longer decrypt vaults (plain login fails with "Already authenticated").
$quoted_pass_cli_path logout 2>/dev/null || true
exec $quoted_pass_cli_path login
SH
    chmod +x "$command_file"
    /usr/bin/open "$command_file" || {
      notify "Proton Pass" "Could not open terminal for login"
      rm -rf "$command_dir"
      exit 0
    }
    (
      sleep 3600
      rm -rf "$command_dir"
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
    exit 0
    ;;

  # Items without a password (API token, custom item) fall back to their first secret field.
  password) copy_field password "Password" || copy_from_json secret ;;
  card)     copy_field number "Card number" || notify "Proton Pass" "No card number on $title" ;;
  cvv)      copy_field verification_number "CVV" || notify "Proton Pass" "No CVV on $title" ;;
  alias)    copy_from_json alias ;;
  custom)   copy_from_json secret ;;

  username)
    # Try the `username` field, fall back to `email`.
    if value="$(pass-cli item view "${ids[@]}" --field username 2>/dev/null)" && [[ -n "$value" ]]; then
      copy_transient "$value"
      remember
      notify "Proton Pass" "Username for $title copied"
    elif value="$(pass-cli item view "${ids[@]}" --field email 2>/dev/null)" && [[ -n "$value" ]]; then
      copy_transient "$value"
      remember
      notify "Proton Pass" "Email for $title copied"
    else
      notify "Proton Pass" "No username or email on $title"
    fi
    ;;

  totp)
    if value="$(pass-cli item totp "${ids[@]}" --output json 2>&1)"; then
      code="$(printf '%s' "$value" | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("totp") or d.get("code") or list(d.values())[0]) if isinstance(d, dict) else d)')" || code=""
      if [[ -n "$code" ]]; then
        copy_transient "$code"
        remember
        notify "Proton Pass" "TOTP for $title copied"
      else
        notify "Proton Pass" "No TOTP configured on $title"
      fi
    else
      notify "Proton Pass" "TOTP failed: $value"
    fi
    ;;

  url)
    json="$(pass-cli item view "${ids[@]}" --output json 2>&1)" || {
      notify "Proton Pass" "Could not read item"
      exit 0
    }
    url="$(printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    urls = d.get("item", {}).get("content", {}).get("content", {}).get("Login", {}).get("urls", [])
    print(urls[0] if urls else "")
except Exception:
    print("")
')"
    # Only web links: item URLs could otherwise point at file://, an app bundle
    # or a custom URL scheme that `open` would launch.
    if [[ "$url" =~ ^https?://[^[:space:]]+$ ]]; then
      /usr/bin/open "$url"
      remember
    elif [[ -n "$url" ]]; then
      notify "Proton Pass" "Refusing to open non-http(s) URL on $title"
    else
      notify "Proton Pass" "No URL on $title"
    fi
    ;;

  details)
    json="$(pass-cli item view "${ids[@]}" --output json 2>&1)" || {
      notify "Proton Pass" "Could not read item"
      exit 0
    }
    # Render a sanitized summary (no secrets) into a dialog.
    # Script via -c, JSON via stdin (upstream used `python3 -` with a heredoc,
    # which took stdin away from the JSON).
    summary="$(printf '%s' "$json" | /usr/bin/python3 -I -c '
import json, sys
title = sys.argv[1]
try:
    d = json.load(sys.stdin)
    item = d.get("item", {})
    content = item.get("content", {})
    inner = content.get("content", {})
    note = content.get("note", "")
    lines = [f"Title: {title}"]
    if "Login" in inner:
        L = inner["Login"]
        if L.get("email"):    lines.append("Email: " + L["email"])
        if L.get("username"): lines.append("Username: " + L["username"])
        if L.get("password"): lines.append("Password: " + "•" * 12)
        if L.get("totp_uri"): lines.append("TOTP: configured")
        for u in L.get("urls", []): lines.append(f"URL: {u}")
    elif "Note" in inner:
        lines.append("Type: note")
    elif "Alias" in inner:
        lines.append("Alias: " + (item.get("alias_email") or "?"))
    elif "Wifi" in inner:
        W = inner["Wifi"] or {}
        if W.get("ssid"):     lines.append("SSID: " + W["ssid"])
        if W.get("password"): lines.append("Password: " + "•" * 12)
    elif "CreditCard" in inner:
        C = inner["CreditCard"]
        if C.get("cardholder_name"): lines.append("Holder: " + C["cardholder_name"])
        if C.get("number"): lines.append("Number: •••• " + C["number"][-4:])
    for f in content.get("extra_fields") or []:
        if f.get("name"): lines.append("Field: " + f["name"] + " (hidden)")
    if note:
        lines.append("")
        lines.append("Note: present (hidden, may contain secrets)")
    print("\n".join(lines))
except Exception as e:
    print(f"(could not parse: {e})")
' "$title")"
    dialog "Proton Pass — $title" "$summary"
    ;;

  *)
    notify "Proton Pass" "Unknown action: $action"
    exit 1
    ;;
esac
