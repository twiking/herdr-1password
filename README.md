# herdr-1password

A [Herdr](https://herdr.dev) plugin that fills 1Password logins into a pane.

Press the key and a popup lists your 1Password logins. Pick one with `enter` and its password is typed into the pane you were working in, as if you typed it yourself; `ctrl-u` types its one-time password instead. Enter is never pressed for you, so nothing is submitted until you do. This works anywhere you can type: `sudo`, `ssh`, a database or login prompt.

If you'd rather paste, the password can be copied to the clipboard instead, and cleared again after 30 seconds.

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

The installer checks the requirements and installs the plugin with `herdr plugin install twiking/herdr-1password`. It then walks you through the settings, explaining each one:

- **1Password account**: which account to list logins from
- **Vault**: all vaults, or only one
- **Tags**: only show logins with these tags
- **Filling in the password**: type it into the pane (the default), or copy it to the clipboard
- **Key binding**: the key that opens the picker, `prefix+u` by default

It adds the key binding to Herdr's `config.toml`, keeping a backup, and ends with a summary of what it saved.

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
| `--fill type\|copy` | Type the password into the pane (default), or copy it to the clipboard |
| `--clear-after SECS` | With `--fill copy`: seconds until the clipboard is cleared (default 30) |
| `--key KEY` | Key binding for the picker |
| `--no-key` | Don't add a key binding |
| `-y`, `--yes` | Don't ask |

## Signing in

With the 1Password app's [CLI integration](https://developer.1password.com/docs/cli/app-integration/) turned on, `op` asks the app to authorize, using system authentication where available. Accounts added with `op account add` instead prompt for the master password in the popup. The session token is cached in `$XDG_RUNTIME_DIR/herdr-1password/session` until it expires after 30 minutes of inactivity.

## Configuration

Settings live in `$(herdr plugin config-dir twiking.1password)/config`, a shell file the installer writes. You can also edit it by hand; see [`config.example`](config.example).

| Setting | Default | |
|---|---|---|
| `account` | `OP_ACCOUNT`, or the last account signed in to | Account shorthand, sign-in address, or ID to list logins from |
| `vault` | all vaults | Only list logins from this vault |
| `tags` | no filter | Only list logins with these comma-separated tags |
| `copy_to_clipboard` | `off` | `off` types the password into the pane; `on` copies it to the clipboard instead |
| `clear_after` | `30` | Seconds until a copied password is cleared from the clipboard |
| `debug` | `off` | `on` keeps the popup open after filling, to read its output |

The key binding lives in Herdr's `config.toml`:

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "twiking.1password.pick"
description = "Fill a 1Password login"
```

## Security

- Secrets never appear in a command line, where other processes could read them from `/proc`. They travel through pipes, and are typed through a raw `pane.send_text` socket request rather than `herdr pane send-text`.
- Typing never presses enter, so nothing is submitted until you do.
- In copy mode, the clipboard is cleared only if it still holds the secret, and Wayland clipboard managers are told it is sensitive.
- The session token for accounts signed in without the app is kept in `$XDG_RUNTIME_DIR`, which is private to you and wiped at logout.

## Actions

| Action | |
|---|---|
| `twiking.1password.pick` | Open the picker over the focused pane |
| `twiking.1password.configure` | Change the settings in a popup |
| `twiking.1password.clear-clipboard` | Clear the clipboard after `clear_after` seconds if it still holds the copied secret; run by the picker in copy mode |

## Troubleshooting

If something fails, the popup stays open to show the error. Set `debug=on` to keep it open after every fill. Herdr logs each run; see them with `herdr plugin log list --plugin twiking.1password`.

## License

[MIT](LICENSE)
