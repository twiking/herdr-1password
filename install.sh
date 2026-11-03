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
  --copy on|off        Copy secrets to the clipboard instead of typing them
  --clear-after SECS   Seconds until a copied secret is cleared
  --key KEY            Key binding for the picker (default prefix+u)
  --no-key             Don't add a key binding
  -y, --yes            Don't ask; keep current values for settings not given
  -h, --help           Show this help
EOF
}

say() { printf '%s\n' "$*"; }
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
    --copy) copy_to_clipboard="${2?--copy needs on or off}"; copy_set=1; shift ;;
    --clear-after) clear_after="${2?--clear-after needs a value}"; clear_set=1; shift ;;
    --key) key="${2?--key needs a value}"; shift ;;
    --no-key) no_key=1 ;;
    -y|--yes) yes=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "${copy_to_clipboard:-off}" in on|off) ;; *) die "--copy takes on or off" ;; esac
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
  say
  say "Settings (enter keeps the current value, - clears it)"
fi

if [ "$interactive" = 1 ] && [ "$account_set" = 0 ]; then
  accounts=$(op account list --format json 2>/dev/null | jq -r '.[] | "\(.url)\t\(.url)  \(.email)"')
  if [ -z "$accounts" ]; then
    warn "1Password CLI has no accounts. Turn on Settings > Developer > Integrate with 1Password CLI in the app, or run 'op account add'."
  else
    # The current choice first, so enter keeps it
    default_line=$(printf '\t%s' "Default (OP_ACCOUNT, or the last account signed in to)")
    chosen=$({
      if [ -n "$account" ]; then
        printf '%s\t%s\n' "$account" "$account  (current)"
        printf '%s\n' "$default_line"
      else
        printf '%s  (current)\n' "$default_line"
      fi
      printf '%s\n' "$accounts" | awk -F '\t' -v cur="$account" '$1 != cur'
    } | pick "1Password account") && account="$chosen"
    say "Account: ${account:-default}"
  fi
fi

if [ "$interactive" = 1 ] && [ "$vault_set" = 0 ]; then
  say "Signing in to list your vaults..."
  vaults=$(op vault list --format json ${account:+--account "$account"} 2>/dev/null | jq -r '.[] | "\(.name)\t\(.name)"')
  if [ -n "$vaults" ]; then
    chosen=$({
      if [ -n "$vault" ]; then
        printf '%s\t%s  (current)\n\t%s\n' "$vault" "$vault" "All vaults"
      else
        printf '\t%s  (current)\n' "All vaults"
      fi
      printf '%s\n' "$vaults" | awk -F '\t' -v cur="$vault" '$1 != cur'
    } | pick "Only list items from") && vault="$chosen"
  else
    warn "couldn't list vaults; type a name instead"
    vault=$(ask "Only list items from this vault, empty for all" "$vault")
    [ "$vault" = - ] && vault=
  fi
  say "Vault: ${vault:-all}"
fi

if [ "$interactive" = 1 ] && [ "$tags_set" = 0 ]; then
  tags=$(ask "Only list items with these tags, comma-separated, empty for all" "$tags")
  [ "$tags" = - ] && tags=
fi

if [ "$interactive" = 1 ] && [ "$copy_set" = 0 ]; then
  if [ "$copy_to_clipboard" = on ]; then default=y; else default=n; fi
  case $(ask "Copy secrets to the clipboard instead of typing them? (y/n)" "$default") in
    y*|Y*) copy_to_clipboard=on ;;
    *) copy_to_clipboard=off ;;
  esac
fi

if [ "$interactive" = 1 ] && [ "$clear_set" = 0 ] && [ "$copy_to_clipboard" = on ]; then
  while :; do
    answer=$(ask "Seconds until the clipboard is cleared" "$clear_after")
    case "$answer" in ''|*[!0-9]*) say "A number of seconds, please." ;; *) clear_after="$answer"; break ;; esac
  done
fi

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

# on: copy the secret to the clipboard instead of typing it into the pane
copy_to_clipboard=$copy_to_clipboard

# Seconds until a copied secret is cleared from the clipboard
clear_after=$clear_after

# on: keep the popup open after filling, to read its output
debug=$debug
EOF
mv "$config.tmp" "$config" || die "couldn't write $config"
say "Saved $config."

# --- Key binding -------------------------------------------------------------------

herdr_config="${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"

if [ "$no_key" = 1 ]; then
  :
elif grep -q "\"$plugin_id.pick\"" "$herdr_config" 2>/dev/null; then
  say "The picker already has a key binding in $herdr_config."
else
  key="${key:-prefix+u}"
  suggested="$key"
  while [ "$interactive" = 1 ]; do
    key=$(ask "Key to open the picker, - for none" "$suggested")
    [ "$key" = - ] && break
    # Bindings set in config.toml, and Herdr's defaults, which it lists commented out
    used=$( { grep -v '^[[:space:]]*#' "$herdr_config" 2>/dev/null; "$herdr" --default-config | sed -n 's/^# *\([a-z_]* *= *\)/\1/p'; } \
      | grep -F "\"$key\"" | head -n 3)
    [ -z "$used" ] && break
    say "$key may already be taken:"
    printf '  %s\n' "$used"
    case $(ask "Use it anyway? (y/n)" n) in y*|Y*) break ;; esac
  done

  case "$key" in
    -) ;;
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
      say "Bound $key in $herdr_config${backup:+ (backup: $backup)}."
      ;;
  esac
fi

if "$herdr" server reload-config >/dev/null 2>&1; then
  say "Reloaded herdr's config."
fi

say
say "Done. Press the key in herdr to fill a login: enter types the password, ctrl-u the one-time password."
finish 0
