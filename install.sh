#!/bin/sh
# Install and configure herdr-1password.
#
#   curl -fsSL https://raw.githubusercontent.com/twiking/herdr-1password/main/install.sh | sh
#   ./install.sh               from a checkout: links it instead of installing from GitHub
#   ./install.sh --configure   only change the settings; also the twiking.1password.configure action
#
# Settings that aren't given as options are asked for, showing the current value.
# With --yes, or without a terminal to ask on, they keep their current or default value.
repo=twiking/herdr-1password
plugin_id=twiking.1password
min_herdr=0.9.1

usage() {
  cat <<EOF
Usage: install.sh [options]

  --configure          Only change the settings, don't install
  --github             Install from GitHub even when run from a checkout
  --ref REF            Git ref to install from GitHub
  --account ACCOUNT    1Password account shorthand, sign-in address, or ID ("" for the default)
  --vault VAULT        Only list items from this vault ("" for all vaults)
  --tags TAGS          Only list items with these comma-separated tags ("" for all items)
  --fill type|copy     Type the password into the pane (default), or copy it to the clipboard
  --clear-after SECS   With --fill copy: seconds until the clipboard is cleared (default 30)
  --key KEY            Key binding for the picker (default prefix+u)
  --no-key             Don't add a key binding
  -y, --yes            Don't ask; keep current values for settings not given
  -h, --help           Show this help
EOF
}

if [ -t 1 ]; then
  bold=$(printf '\033[1m') reset=$(printf '\033[0m')
else
  bold= reset=
fi

say() { printf '%s\n' "$*"; }

# heading TITLE [LINE...]: a section title with its explanation
heading() {
  printf '\n%s%s%s\n' "$bold" "$1" "$reset"
  shift
  for line in "$@"; do say "$line"; done
}
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; finish 1; }

# Inside the configure popup, keep the result on screen until it's read
finish() {
  if [ "${HERDR_PLUGIN_ENTRYPOINT_ID:-}" = configure ]; then
    printf '\nPress enter to close.'
    read -r _ </dev/tty
  fi
  exit "$1"
}

# Single-quote $1 for sh
q() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

has() { command -v "$1" >/dev/null 2>&1; }

# $1 >= $2, comparing dotted version numbers
version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}

configure_only=0 github=0 ref= yes=0 key= no_key=0
account_set=0 vault_set=0 tags_set=0 copy_set=0 clear_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --configure) configure_only=1 ;;
    --github) github=1 ;;
    --ref) ref="${2?--ref needs a value}"; shift ;;
    --account) account="${2?--account needs a value}"; account_set=1; shift ;;
    --vault) vault="${2?--vault needs a value}"; vault_set=1; shift ;;
    --tags) tags="${2?--tags needs a value}"; tags_set=1; shift ;;
    --fill)
      case "${2?--fill needs type or copy}" in
        type) copy_to_clipboard=off ;;
        copy) copy_to_clipboard=on ;;
        *) printf 'error: --fill takes type or copy\n' >&2; exit 2 ;;
      esac
      copy_set=1; shift ;;
    --clear-after) clear_after="${2?--clear-after needs a value}"; clear_set=1; shift ;;
    --key) key="${2?--key needs a value}"; shift ;;
    --no-key) no_key=1 ;;
    -y|--yes) yes=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "${clear_after:-30}" in ''|*[!0-9]*) die "--clear-after takes a number of seconds" ;; esac

# Prompts go to the terminal even when the script itself is piped into sh
interactive=0
if [ "$yes" = 0 ] && { true </dev/tty; } 2>/dev/null; then
  interactive=1
fi

# ask PROMPT CURRENT: print the answer, or CURRENT on enter
ask() {
  if [ -n "$2" ]; then printf '%s [%s]: ' "$1" "$2" >/dev/tty; else printf '%s: ' "$1" >/dev/tty; fi
  read -r reply </dev/tty
  printf '%s' "${reply:-$2}"
}

# pick HEADER < "value<TAB>label" lines: print the chosen value; fail if dismissed
pick() {
  choice=$(fzf --height=40% --layout=reverse --no-multi --delimiter='\t' --with-nth=2 \
    --header="$1" --prompt='> ') || return 1
  printf '%s' "$choice" | cut -f1
}

# --- Requirements ------------------------------------------------------------------

say "${bold}herdr-1password$reset"
say "Fill in passwords from 1Password without leaving Herdr: press a key, pick a"
say "login from the list, and its password goes into the pane you were working in."

herdr="${HERDR_BIN_PATH:-herdr}"
has "$herdr" || die "herdr isn't installed; see https://herdr.dev"
herdr_version=$("$herdr" --version | awk '{print $2}')
version_ge "$herdr_version" "$min_herdr" || die "herdr $herdr_version is too old; $min_herdr or newer is needed (herdr update)"

missing=
for dep in op jq fzf; do
  has "$dep" || missing="$missing $dep"
done
has socat || has nc || missing="$missing socat"
[ -z "$missing" ] || die "missing:$missing. The 1Password CLI is at https://developer.1password.com/docs/cli/get-started/"

# --- Install -----------------------------------------------------------------------

# Piped into sh, $0 is the shell rather than this file
checkout=
case "$0" in
  *install.sh) [ -f "$(dirname "$0")/herdr-plugin.toml" ] && checkout=$(cd "$(dirname "$0")" && pwd) ;;
esac

if [ "$configure_only" = 0 ]; then
  heading "Installing the plugin"
  current=$("$herdr" plugin list --json --plugin "$plugin_id" 2>/dev/null \
    | jq -r '.result.plugins[]? | "\(.source.kind)\t\(.plugin_root)"')
  kind=$(printf '%s' "$current" | cut -f1)
  root=$(printf '%s' "$current" | cut -f2)

  if [ -n "$checkout" ] && [ "$github" = 0 ]; then
    if [ "$kind" = local ] && [ "$root" = "$checkout" ]; then
      say "Already linked to $checkout."
    else
      if [ "$kind" = local ]; then
        "$herdr" plugin unlink "$plugin_id" >/dev/null || die "couldn't unlink $root"
      elif [ -n "$kind" ]; then
        "$herdr" plugin uninstall "$plugin_id" >/dev/null || die "couldn't uninstall the GitHub copy"
      fi
      "$herdr" plugin link "$checkout" >/dev/null || die "couldn't link $checkout"
      say "Linked $checkout."
    fi
  else
    [ "$kind" = local ] && die "$plugin_id is linked from $root; run 'herdr plugin unlink $plugin_id' first"
    say "Installing $repo from GitHub..."
    "$herdr" plugin install "$repo" --yes ${ref:+--ref "$ref"} >/dev/null || die "herdr plugin install $repo failed"
    say "Installed."
  fi
fi

config_dir=$("$herdr" plugin config-dir "$plugin_id" 2>/dev/null) \
  || die "$plugin_id isn't installed; run install.sh without --configure"
config="$config_dir/config"

# --- Settings ----------------------------------------------------------------------

# Current values, read in a subshell so the file can't touch this script's variables
if [ -f "$config" ]; then
  eval "$(
    account= vault= tags= copy_to_clipboard=off clear_after=30 debug=off
    . "$config" >/dev/null 2>&1
    printf 'cur_account=%s\n' "$(q "$account")"
    printf 'cur_vault=%s\n' "$(q "$vault")"
    printf 'cur_tags=%s\n' "$(q "$tags")"
    printf 'cur_copy_to_clipboard=%s\n' "$(q "$copy_to_clipboard")"
    printf 'cur_clear_after=%s\n' "$(q "$clear_after")"
    printf 'cur_debug=%s\n' "$(q "$debug")"
  )"
fi
[ "$account_set" = 1 ] || account="${cur_account:-}"
[ "$vault_set" = 1 ] || vault="${cur_vault:-}"
[ "$tags_set" = 1 ] || tags="${cur_tags:-}"
[ "$copy_set" = 1 ] || copy_to_clipboard="${cur_copy_to_clipboard:-off}"
[ "$clear_set" = 1 ] || clear_after="${cur_clear_after:-30}"
debug="${cur_debug:-off}"

if [ "$interactive" = 1 ]; then
  heading "Settings" \
    "A few questions about which logins the picker shows and how it fills them in." \
    "Enter keeps the value shown first or in [brackets]. Change them any time by" \
    "running install.sh --configure, or the twiking.1password.configure action in Herdr."
fi

if [ "$interactive" = 1 ] && [ "$account_set" = 0 ]; then
  heading "1Password account" \
    "The picker lists logins from this account. If you have only one, either choice works."
  accounts=$(op account list --format json 2>/dev/null | jq -r '.[] | "\(.url)\t\(.url)  \(.email)"')
  if [ -z "$accounts" ]; then
    warn "1Password CLI has no accounts. Turn on Settings > Developer > Integrate with 1Password CLI in the app, or run 'op account add'."
  else
    # The current choice first, so enter keeps it
    default_line=$(printf '\t%s' "The default: OP_ACCOUNT, or the account you last signed in to")
    chosen=$({
      if [ -n "$account" ]; then
        printf '%s\t%s\n' "$account" "$account  (current)"
        printf '%s\n' "$default_line"
      else
        printf '%s  (current)\n' "$default_line"
      fi
      printf '%s\n' "$accounts" | awk -F '\t' -v cur="$account" '$1 != cur'
    } | pick "Choose an account") && account="$chosen"
    say "Account: ${account:-the default}"
  fi
fi

if [ "$interactive" = 1 ] && [ "$vault_set" = 0 ]; then
  heading "Vault" \
    "Show logins from all your vaults, or only from one, such as a work vault." \
    "Asking 1Password for your vaults; it may ask you to unlock it..."
  vaults=$(op vault list --format json ${account:+--account "$account"} 2>/dev/null | jq -r '.[] | "\(.name)\t\(.name)"')
  if [ -n "$vaults" ]; then
    chosen=$({
      if [ -n "$vault" ]; then
        printf '%s\t%s  (current)\n\t%s\n' "$vault" "$vault" "All vaults"
      else
        printf '\t%s  (current)\n' "All vaults"
      fi
      printf '%s\n' "$vaults" | awk -F '\t' -v cur="$vault" '$1 != cur'
    } | pick "Choose a vault") && vault="$chosen"
  else
    warn "couldn't list your vaults; type a vault name instead"
    vault=$(ask "Vault name, empty for all vaults, - to clear" "$vault")
    [ "$vault" = - ] && vault=
  fi
  say "Vault: ${vault:-all vaults}"
fi

if [ "$interactive" = 1 ] && [ "$tags_set" = 0 ]; then
  heading "Tags" \
    "Show only logins tagged in 1Password with these tags, comma-separated," \
    "for example: ssh,servers. Leave empty to show every login; type - to clear."
  tags=$(ask "Tags to show" "$tags")
  [ "$tags" = - ] && tags=
  say "Tags: ${tags:-none, every login is shown}"
fi

if [ "$interactive" = 1 ] && [ "$copy_set" = 0 ]; then
  heading "Filling in the password" \
    "Type: the password is typed into the pane you opened the picker from, as if you" \
    "      typed it yourself. Enter isn't pressed, so nothing is submitted until you do." \
    "      Works anywhere you can type: sudo, ssh, a database or login prompt." \
    "Copy: the password is copied to the clipboard for you to paste, and cleared" \
    "      again after a number of seconds."
  if [ "$copy_to_clipboard" = on ]; then
    chosen=$(printf 'on\t%s\noff\t%s\n' "Copy it to the clipboard (current)" "Type it into the pane (default)" \
      | pick "How should the password be filled in?")
  else
    chosen=$(printf 'off\t%s\non\t%s\n' "Type it into the pane (default, current)" "Copy it to the clipboard" \
      | pick "How should the password be filled in?")
  fi && copy_to_clipboard="$chosen"
  if [ "$copy_to_clipboard" = on ] && [ "$clear_set" = 0 ]; then
    while :; do
      answer=$(ask "Clear the clipboard after how many seconds" "$clear_after")
      case "$answer" in ''|*[!0-9]*) say "Please enter a number of seconds." ;; *) clear_after="$answer"; break ;; esac
    done
  fi
fi

if [ "$copy_to_clipboard" = on ]; then
  filling="copied to the clipboard, cleared after ${clear_after}s"
else
  filling="typed into the pane"
fi
[ "$interactive" = 1 ] && [ "$copy_set" = 0 ] && say "Passwords are $filling."

umask 077
cat > "$config.tmp" <<EOF
# herdr-1password settings. Sourced by sh: edit freely, or re-run install.sh --configure
# (also the twiking.1password.configure action).

# Account shorthand, sign-in address, or ID; see \`op account list\`.
# Empty uses OP_ACCOUNT, or the account you last signed in to.
account=$(q "$account")

# Only list items from this vault. Empty lists all vaults.
vault=$(q "$vault")

# Only list items with these tags, comma-separated. Empty lists all items.
tags=$(q "$tags")

# off: type the secret into the pane. on: copy it to the clipboard instead.
copy_to_clipboard=$copy_to_clipboard

# Seconds until a copied secret is cleared from the clipboard
clear_after=$clear_after

# on: keep the popup open after filling, to read its output
debug=$debug
EOF
mv "$config.tmp" "$config" || die "couldn't write $config"

# --- Key binding -------------------------------------------------------------------

herdr_config="${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
prefix=$(sed -n 's/^prefix *= *"\(.*\)".*/\1/p' "$herdr_config" 2>/dev/null | head -n 1)
prefix="${prefix:-ctrl+b}"

# The key of an existing binding: the last key line before the line naming the action
bound=$(awk -v cmd="\"$plugin_id.pick\"" '
  /^[[:space:]]*key[[:space:]]*=/ { k = $0; sub(/^[^"]*"/, "", k); sub(/".*/, "", k) }
  index($0, cmd) && /^[[:space:]]*command[[:space:]]*=/ { print k; exit }' "$herdr_config" 2>/dev/null)

if [ "$no_key" = 1 ]; then
  key=
elif [ -n "$bound" ]; then
  key="$bound"
  if [ "$interactive" = 1 ]; then
    heading "Key binding" \
      "The picker opens with $bound. To change it, edit the twiking.1password.pick" \
      "binding in $herdr_config."
  fi
else
  key="${key:-prefix+u}"
  if [ "$interactive" = 1 ]; then
    heading "Key binding" \
      "The key that opens the picker in Herdr. prefix+u means: press your Herdr prefix" \
      "($prefix), let go, then press u. Type - to skip; you can bind the" \
      "twiking.1password.pick action yourself later."
  fi
  suggested="$key"
  while [ "$interactive" = 1 ]; do
    key=$(ask "Key" "$suggested")
    [ "$key" = - ] && break
    # Bindings set in config.toml, and Herdr's defaults, which it lists commented out
    used=$( { grep -v '^[[:space:]]*#' "$herdr_config" 2>/dev/null; "$herdr" --default-config | sed -n 's/^# *\([a-z_]* *= *\)/\1/p'; } \
      | grep -F "\"$key\"" | head -n 3)
    [ -z "$used" ] && break
    say "$key may already be used by:"
    printf '  %s\n' "$used"
    case $(ask "Use it anyway? (y/n)" n) in y*|Y*) break ;; esac
  done

  case "$key" in
    -) key= ;;
    *[\"\\]*) die "not a valid key: $key" ;;
    *)
      mkdir -p "$(dirname "$herdr_config")"
      # Only a problem the binding adds counts; the config may have had warnings already
      checked_before=$("$herdr" config check 2>&1)
      backup=
      if [ -f "$herdr_config" ]; then
        backup="$herdr_config.bak-$(date +%Y-%m-%d-%H%M%S)"
        cp "$herdr_config" "$backup" || die "couldn't back up $herdr_config"
      fi
      cat >> "$herdr_config" <<EOF

# Open the 1Password picker (added by herdr-1password's install.sh)
[[keys.command]]
key = "$key"
type = "plugin_action"
command = "$plugin_id.pick"
description = "Fill a 1Password login"
EOF
      if [ "$("$herdr" config check 2>&1)" != "$checked_before" ]; then
        if [ -n "$backup" ]; then mv "$backup" "$herdr_config"; else rm -f "$herdr_config"; fi
        die "herdr rejected the key binding; $herdr_config is unchanged"
      fi
      say "Added the binding to $herdr_config${backup:+ (backup: $backup)}."
      "$herdr" server reload-config >/dev/null 2>&1
      ;;
  esac
fi

# --- Summary -----------------------------------------------------------------------

heading "Done"
say "  Account   ${account:-the default}"
say "  Vault     ${vault:-all vaults}"
say "  Tags      ${tags:-none}"
say "  Password  $filling"
say "  Key       ${key:-none}"
say
say "Settings are saved in $config."
if [ -n "$key" ]; then
  if [ "$copy_to_clipboard" = on ]; then verb=copies; else verb=types; fi
  say "In Herdr, press $key, pick a login, and press enter: the picker $verb its password."
  say "Press ctrl-u instead for its one-time password, or esc to cancel."
fi
finish 0
