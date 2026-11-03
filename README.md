# herdr-1password

A [Herdr](https://herdr.dev) plugin that fills 1Password logins into a pane, ported from [tmux-1password](https://github.com/yardnsm/tmux-1password).

Press the key and a popup lists your Login and Password items. Pick one with `enter` to type its password into the pane you were in, or with `ctrl-u` to type its one-time password. Nothing is submitted; press enter yourself.

## Requirements

- Herdr 0.9.1 or newer, on Linux or macOS
- [1Password CLI](https://developer.1password.com/docs/cli/get-started/) 2.x
- `fzf` and `jq`
- `socat`, or an `nc` that supports `-U` and `-N`
- For copy mode: `wl-copy`, `pbcopy`, `xclip`, or `xsel`

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/twiking/herdr-1password/main/install.sh | sh
```

The installer checks the requirements, installs the plugin with `herdr plugin install twiking/herdr-1password`, then asks for your settings:

- which 1Password account and vault to use
- which tags to filter on
- whether to copy to the clipboard instead of typing
- a key binding, `prefix+u` by default

It adds the binding to Herdr's `config.toml`, keeping a backup, and reloads the config.

Or install with Herdr directly and configure from inside it:

```sh
herdr plugin install twiking/herdr-1password
herdr plugin action invoke twiking.1password.configure
```

From a clone, `./install.sh` links the checkout instead, which suits working on the plugin.

To change settings later, run `install.sh --configure` or the `twiking.1password.configure` action.

### Unattended installs

Settings can be passed as options; `--yes` keeps current values for the rest instead of asking:

```sh
curl -fsSL https://raw.githubusercontent.com/twiking/herdr-1password/main/install.sh \
  | sh -s -- --yes --account my.1password.com --vault Work --key prefix+u
```

| Option | |
|---|---|
| `--configure` | Only change the settings, don't install |
| `--github` | Install from GitHub even when run from a checkout |
| `--ref REF` | Git ref to install from GitHub |
| `--account ACCOUNT` | Account shorthand, sign-in address, or ID; `""` for the default |
| `--vault VAULT` | Only list items from this vault; `""` for all vaults |
| `--tags TAGS` | Only list items with these comma-separated tags; `""` for all items |
| `--copy on\|off` | Copy secrets to the clipboard instead of typing them |
| `--clear-after SECS` | Seconds until a copied secret is cleared |
| `--key KEY` | Key binding for the picker |
| `--no-key` | Don't add a key binding |
| `-y`, `--yes` | Don't ask |

## Signing in

With the 1Password app's [CLI integration](https://developer.1password.com/docs/cli/app-integration/) turned on, `op` asks the app to authorize, using system authentication where available. Accounts added with `op account add` instead prompt for the master password in the popup. The session token is cached in `$XDG_RUNTIME_DIR/herdr-1password/session` until it expires after 30 minutes of inactivity.

## Configuration

Settings live in `$(herdr plugin config-dir twiking.1password)/config`, a shell file the installer writes. You can also edit it by hand; see [`config.example`](config.example).

| Setting | Default | tmux-1password option |
|---|---|---|
| `account` | `OP_ACCOUNT`, or the last account signed in to | `@1password-account` |
| `vault` | all vaults | `@1password-vault` |
| `tags` | no filter | `@1password-filter-tags` |
| `copy_to_clipboard` | `off` | `@1password-copy-to-clipboard` |
| `clear_after` | `30` seconds | (fixed at 30) |
| `debug` | `off` | `@1password-debug` |

The key binding lives in Herdr's `config.toml` rather than `@1password-key`:

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "twiking.1password.pick"
description = "Fill a 1Password login"
```

## Differences from tmux-1password

- The picker is a popup over the pane, not a split under it.
- Each row shows the username and vault. Items are picked by ID, so items with the same title, or with commas in it, work.
- Secrets never appear in a command line, where other processes could read them from `/proc`. They are typed through a raw `pane.send_text` socket request rather than `herdr pane send-text`.
- Items without a field marked as the password fall back to their first concealed field.
- In copy mode, the clipboard is cleared only if it still holds the secret, and Wayland clipboard managers are told it is sensitive.

## Actions

| Action | |
|---|---|
| `twiking.1password.pick` | Open the picker over the focused pane |
| `twiking.1password.configure` | Change the settings in a popup |
| `twiking.1password.clear-clipboard` | Clear the clipboard after `clear_after` seconds if it still holds the copied secret; run by the picker in copy mode |

## Troubleshooting

If something fails, the popup stays open to show the error. Set `debug=on` to keep it open after every fill. Herdr logs each run; see them with `herdr plugin log list --plugin twiking.1password`.

## License

[MIT](LICENSE). The approach and the original shell code come from [tmux-1password](https://github.com/yardnsm/tmux-1password) by Yarden Sod-Moriah, also MIT.
