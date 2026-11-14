#!/bin/bash
# Dispatch an Alfred action against a Proton Pass item.
# Receives one argument: ACTION|SHARE_ID|ITEM_ID|TITLE
#
# ACTION ∈ {password, username, totp, url, details, login}

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
source "$(dirname "$0")/lib.sh"

arg="${1:-}"
IFS='|' read -r action share_id item_id title <<<"$arg"

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

  password)
    # Login items: the password field. Anything else (API token, custom item):
    # fall back to the first secret field, see first_secret below.
    if value="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --field password 2>/dev/null)" && [[ -n "$value" ]]; then
      copy_transient "$value"
      notify "Proton Pass" "Password for $title copied (clears in ${CLIP_CLEAR_SECONDS}s)"
    elif json="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --output json 2>&1)"; then
      # Script via -c, JSON via stdin. Prints "<field name>\n<value>" or nothing.
      secret="$(printf '%s' "$json" | /usr/bin/python3 -I -c '
import json, sys
try:
    c = json.load(sys.stdin)["item"]["content"]
    fields = []
    for sec in (c.get("content", {}).get("Custom", {}) or {}).get("sections", []):
        fields += sec.get("section_fields", [])
    fields += c.get("extra_fields", [])
    # Hidden fields are the real secrets; plain text is the fallback.
    for kind in ("Hidden", "Text"):
        for f in fields:
            v = (f.get("content") or {}).get(kind)
            if v:
                print(f.get("name", "")); print(v); sys.exit()
except Exception:
    pass
')" || secret=""
      if [[ -n "$secret" ]]; then
        field_name="${secret%%$'\n'*}"
        copy_transient "${secret#*$'\n'}"
        notify "Proton Pass" "${field_name:-Secret} of $title copied (clears in ${CLIP_CLEAR_SECONDS}s)"
      else
        notify "Proton Pass" "No password or secret field on $title"
      fi
    else
      notify "Proton Pass" "Could not read item: $json"
    fi
    ;;

  username)
    # Try the `username` field, fall back to `email`.
    if value="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --field username 2>/dev/null)" && [[ -n "$value" ]]; then
      copy_transient "$value"
      notify "Proton Pass" "Username for $title copied"
    elif value="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --field email 2>/dev/null)" && [[ -n "$value" ]]; then
      copy_transient "$value"
      notify "Proton Pass" "Email for $title copied"
    else
      notify "Proton Pass" "No username or email on $title"
    fi
    ;;

  totp)
    if value="$(pass-cli item totp --share-id "$share_id" --item-id "$item_id" --output json 2>&1)"; then
      code="$(printf '%s' "$value" | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("totp") or d.get("code") or list(d.values())[0]) if isinstance(d, dict) else d)')" || code=""
      if [[ -n "$code" ]]; then
        copy_transient "$code"
        notify "Proton Pass" "TOTP for $title copied"
      else
        notify "Proton Pass" "No TOTP configured on $title"
      fi
    else
      notify "Proton Pass" "TOTP failed: $value"
    fi
    ;;

  url)
    json="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --output json 2>&1)" || {
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
    elif [[ -n "$url" ]]; then
      notify "Proton Pass" "Refusing to open non-http(s) URL on $title"
    else
      notify "Proton Pass" "No URL on $title"
    fi
    ;;

  details)
    json="$(pass-cli item view --share-id "$share_id" --item-id "$item_id" --output json 2>&1)" || {
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
    elif "CreditCard" in inner:
        C = inner["CreditCard"]
        if C.get("cardholder_name"): lines.append("Holder: " + C["cardholder_name"])
        if C.get("number"): lines.append("Number: •••• " + C["number"][-4:])
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
