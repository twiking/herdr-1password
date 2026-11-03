#!/bin/sh
# Usage: 1password.sh open|pick|configure|clear-clipboard
#
# open:            open the picker popup over the focused pane (the pick action).
# configure:       open install.sh --configure in a popup (the configure action).
# pick:            the popup itself. Lists login and password items with fzf, then types
#                  the chosen password (enter) or one-time password (ctrl-u) into the
#                  pane that was focused, or copies it when copy_to_clipboard is on.
# clear-clipboard: wait clear_after seconds, then clear the clipboard if it still holds
#                  the copied secret. Runs as a plugin action so it outlives the popup.
#
# A port of github.com/yardnsm/tmux-1password. Settings are read from the shell file
# $HERDR_PLUGIN_CONFIG_DIR/config; see README.md.
#
# Secrets never appear in a command line, where any process could read them from /proc:
# they travel through pipes and builtins only, and reach the pane as a raw socket
# request instead of `herdr pane send-text`.
herdr="${HERDR_BIN_PATH:-herdr}"
cmd="${1:-open}"

account=
vault=
tags=
copy_to_clipboard=off
clear_after=30
debug=off
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/twiking.1password}"
[ -f "$config_dir/config" ] && . "$config_dir/config"

# The cached session token and the clipboard fingerprint; XDG_RUNTIME_DIR is tmpfs,
# private to the user and wiped at logout
runtime_dir="${XDG_RUNTIME_DIR:-${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}}/herdr-1password"
umask 077
mkdir -p "$runtime_dir"

notify() {
  "$herdr" notification show "1Password" --body "$1" --sound none >/dev/null 2>&1
}

fingerprint() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

clipboard() {
  case "$1" in
    copy)
      if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1; then wl-copy --sensitive
      elif command -v pbcopy >/dev/null 2>&1; then pbcopy
      elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard
      elif command -v xsel >/dev/null 2>&1; then xsel -bi
      else return 1
      fi ;;
    paste)
      if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-paste >/dev/null 2>&1; then wl-paste -n 2>/dev/null
      elif command -v pbpaste >/dev/null 2>&1; then pbpaste
      elif command -v xclip >/dev/null 2>&1; then xclip -o -selection clipboard
      elif command -v xsel >/dev/null 2>&1; then xsel -bo
      fi ;;
    clear)
      if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1; then wl-copy --clear
      else printf '' | clipboard copy
      fi ;;
  esac
}

# Type stdin into pane $1 with a raw pane.send_text request. The server answers and
# closes the connection, so the client exits as soon as the reply is in.
send_to_pane() {
  request=$(jq -cRs --arg pane "$1" \
    '{id: "herdr-1password", method: "pane.send_text", params: {pane_id: $pane, text: .}}') || return 1
  socket="${HERDR_SOCKET_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock}"
  if command -v socat >/dev/null 2>&1; then
    reply=$(printf '%s\n' "$request" | socat -t 5 - "UNIX-CONNECT:$socket")
  else
    reply=$(printf '%s\n' "$request" | nc -UN "$socket")
  fi
  printf '%s' "$reply" | jq -e '.result' >/dev/null 2>&1
}

if [ "$cmd" = open ]; then
  # A popup has no pane of its own, so hand it the pane to type into
  pane=$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-null}" | jq -r '.focused_pane_id // empty' 2>/dev/null)
  pane="${pane:-$HERDR_PANE_ID}"
  if [ -z "$pane" ]; then
    notify "No focused pane to fill"
    exit 1
  fi
  exec "$herdr" plugin pane open --plugin "${HERDR_PLUGIN_ID:-twiking.1password}" \
    --entrypoint picker --env "HERDR_1PASSWORD_PANE=$pane" >/dev/null
fi

if [ "$cmd" = configure ]; then
  exec "$herdr" plugin pane open --plugin "${HERDR_PLUGIN_ID:-twiking.1password}" \
    --entrypoint configure >/dev/null
fi

if [ "$cmd" = clear-clipboard ]; then
  sleep "$clear_after"
  # Leave the clipboard alone if something else has been copied since
  if [ "$(clipboard paste | fingerprint)" = "$(cat "$runtime_dir/clipboard" 2>/dev/null)" ]; then
    clipboard clear
  fi
  rm -f "$runtime_dir/clipboard"
  exit 0
fi

# pick, running inside the popup from here on

# Without this the popup closes before an error can be read
finish() {
  if [ "$debug" = on ] || [ "$1" -ne 0 ]; then
    printf '\nPress enter to close.'
    read -r _
  fi
  exit "$1"
}

fail() {
  printf '%s\n' "$1" >&2
  finish 1
}

for dep in op jq fzf; do
  command -v "$dep" >/dev/null 2>&1 || fail "herdr-1password needs '$dep', which isn't installed."
done

target="$HERDR_1PASSWORD_PANE"
[ -n "$target" ] || fail "No target pane; open the picker with the twiking.1password.pick action."

[ -n "$account" ] && export OP_ACCOUNT="$account"

# With the 1Password app integration op signs in by itself (prompting the app if
# needed) and prints no token. Accounts added with `op account add` print a session
# token instead, which is cached so the master password is only asked for again once
# the session expires.
session_file="$runtime_dir/session"
session=$(cat "$session_file" 2>/dev/null)
token=$(op signin --force --raw ${session:+--session "$session"}) || fail "1Password CLI sign-in failed."
if [ -n "$token" ]; then
  printf '%s' "$token" > "$session_file"
  session="$token"
fi
clear

printf 'Fetching items...'
items=$(op item list --format json --categories Login,Password \
    ${vault:+--vault "$vault"} ${tags:+--tags "$tags"} ${session:+--session "$session"} \
  | jq -r '
    sort_by(.title | ascii_downcase)[]
    # id, then title with the username and vault dimmed
    | [.id, "\(.title)\u001b[2m  \([.additional_information, .vault.name] | map(select(. != null and . != "")) | join(" · "))\u001b[0m"]
    | @tsv') || fail "Couldn't list 1Password items."
clear
[ -n "$items" ] || fail "No login or password items found."

selection=$(printf '%s\n' "$items" | fzf --ansi --no-multi --layout=reverse --info=inline \
  --delimiter='\t' --with-nth=2.. --prompt='1Password> ' \
  --header='enter=password, ctrl-u=one-time password' --expect=enter,ctrl-u)
key=$(printf '%s\n' "$selection" | sed -n 1p)
id=$(printf '%s\n' "$selection" | sed -n 2p | cut -f1)
[ -n "$id" ] || finish 0

case "$key" in
  ctrl-u)
    printf 'Fetching one-time password...'
    secret=$(op item get "$id" --otp ${session:+--session "$session"}) \
      || fail "That item has no one-time password." ;;
  *)
    printf 'Fetching password...'
    # The field whose purpose is the password, else the first concealed field
    secret=$(op item get "$id" --fields type=concealed --format json ${session:+--session "$session"} \
      | jq -r '[.] + [] | flatten | (map(select(.purpose == "PASSWORD")) + .) | .[0].value // empty')
    [ -n "$secret" ] || fail "That item has no password." ;;
esac
clear

if [ "$copy_to_clipboard" = on ]; then
  printf '%s' "$secret" | clipboard copy || fail "No clipboard tool found (wl-copy, pbcopy, xclip or xsel)."
  printf '%s' "$secret" | fingerprint > "$runtime_dir/clipboard"
  "$herdr" plugin action invoke clear-clipboard --plugin "${HERDR_PLUGIN_ID:-twiking.1password}" >/dev/null 2>&1
  notify "Copied; the clipboard clears in ${clear_after}s"
else
  printf '%s' "$secret" | send_to_pane "$target" || fail "Couldn't type into pane $target."
fi

finish 0
