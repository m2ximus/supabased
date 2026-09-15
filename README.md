# supabased — per-folder Supabase CLI accounts

The Supabase CLI holds one login at a time. supabased (command: `sbx`) keeps tokens for any number of
accounts in the macOS Keychain and makes `supabase ...` use the right one for the
folder you are in — no manual switching.

## Install

```sh
git clone https://github.com/m2ximus/supabased.git ~/supabased && ~/supabased/install.sh
```

The installer symlinks `bin/sbx` into `~/.local/bin` and appends
`eval "$(sbx init zsh)"` to `~/.zshrc` (backup at `~/.zshrc.bak-sbx`). That line
defines a shell function:

```zsh
supabase() { command env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u PS4 -u CURL_HOME -u XDG_CONFIG_HOME sbx exec -- supabase "$@"; }
```

(The `env -u` list strips variables that could alter how bash or curl behave;
see the security model below.)

Requirements: macOS, system bash 3.2, `curl`, `jq` (`/usr/bin/jq`), the `supabase` CLI.

## Add accounts

```sh
sbx add work        # prompts for a token, input hidden
sbx add personal
sbx list            # work *   (the first account becomes the default)
```

Create a personal access token at <https://supabase.com/dashboard/account/tokens>
(they start with `sbp_`). The token is verified against the Management API
before it is stored.

Use the hidden prompt. Piping (`echo sbp_... | sbx add work`) works but leaves
the token in your shell history.

## Questions

**What do I need first?**
macOS 15 or later (it ships `jq` and `curl`), zsh (the macOS default), git, and
the [Supabase CLI](https://supabase.com/docs/guides/cli/getting-started)
(`brew install supabase/tap/supabase`).

**Where do I get a token?**
Log in to Supabase as the account you want to add, open
<https://supabase.com/dashboard/account/tokens>, click **Generate new token**,
name it (e.g. `sbx`) and copy it. It starts with `sbp_`.

**I pasted my token and nothing appeared.**
That's intended — the prompt hides what you type. Paste once and press Enter.

**How do I add a second account?**
Log out of the Supabase dashboard, log in as the other account, generate a token
there, and run `sbx add` with a different name, e.g. `sbx add client-x`.

**`sbx: command not found` or `supabase` isn't switching accounts.**
Open a new terminal tab — the installer's changes only load in new shells. If it
still fails, make sure `~/.local/bin` is on your `PATH`.

**How do I know which account was used?**
Each `supabase` command prints `sbx → <account> (<reason>)` first. Run
`sbx status` in any folder to check without running anything.

**It says `no account for this folder`.**
The folder isn't linked to a Supabase project and you have no default. Run
`supabase link` in the project, or `sbx pin <name>`, or `sbx default <name>`.

**It says `no saved account owns project …`.**
None of your saved accounts can see that project. Add the account that owns it
with `sbx add`, then try again (adding an account clears the cache).

**`token rejected by Supabase API`.**
The token was mistyped, revoked, or you're offline. Generate a new one and retry.

**Is it safe to paste my token?**
Only into the hidden `sbx add` prompt. Never paste tokens into chats, websites,
issues or screenshots. You can revoke a token any time on the tokens page.

**How do I remove an account?**
`sbx remove <name>` deletes its token from the Keychain and forgets it. Also
revoke the token on the Supabase tokens page if you no longer need it.

**How do I uninstall?**
Remove each account with `sbx remove <name>`, delete the
`eval "$(sbx init zsh)"` line from `~/.zshrc`, then
`rm ~/.local/bin/sbx && rm -rf ~/.config/sbx ~/supabased`.

**Does it work on Linux or Windows?**
No — it relies on the macOS Keychain.

## How resolution works

For each `supabase ...` invocation, `sbx` walks up from `$PWD` to `/` and takes
the first hit:

1. A `.sbx` file (first line = account name) — an explicit pin from `sbx pin <name>`.
2. `supabase/.temp/project-ref` (written by `supabase link`) — the owning account
   is looked up in a small cache, or by asking each account's `GET /v1/projects`
   once, then cached in `~/.config/sbx/ref-cache`. If no saved account owns the
   project, resolution stops here: `supabase` runs untouched (with a notice)
   rather than using the default account's token.
3. The default account (`sbx default <name>`) — only when no project-ref was found.
4. Nothing — `supabase` runs untouched with its own login, and a notice is printed.

If `SUPABASE_ACCESS_TOKEN` is already set in your environment, `sbx` passes it
through unchanged.

`sbx status` shows which account, why, and which project. `sbx which [dir]`
prints the same for any folder. `sbx refresh` clears the ref cache.

Resolution is by `$PWD`, not by `supabase --workdir`. Run from the project folder.

`.sbx` pin files contain only an account name and are safe to commit. On a
machine without that account name saved, the pin is ignored with a warning.

## Commands

| command | what it does |
| --- | --- |
| `sbx add <name>` | store a token (prompted) after verifying it |
| `sbx remove <name>` | delete the token and forget the account |
| `sbx list [--projects]` | list accounts, `*` marks the default |
| `sbx default <name>` | set the fallback account |
| `sbx pin <name>` | write `./.sbx` |
| `sbx which [dir]` | `NAME<TAB>SOURCE<TAB>REF` for a folder |
| `sbx status` | account / source / project for the current folder |
| `sbx exec -- cmd ...` | run `cmd` with `SUPABASE_ACCESS_TOKEN` set for it only |
| `sbx refresh` | clear the project-ref cache |
| `sbx init zsh` | print the `supabase` wrapper function |

## Security model

- **Tokens live only in the login Keychain** (service `sbx-supabase`). Nothing
  under `~/.config/sbx` is secret: it holds account names, project refs and the
  ref-to-account cache, in a mode-700 directory with mode-600 files.
- **Tokens never appear on a command line.** Keychain writes go through
  `security -i` on stdin; API calls pass the header through `curl -H @-`. Nothing
  shows up in `ps`.
- **Tokens are never printed** — not by `list`, `status`, `which`, or any error.
- **Only the child process gets the token.** `sbx exec` sets
  `SUPABASE_ACCESS_TOKEN` for the `supabase` process it `exec`s and nothing
  else; your interactive shell never has it exported.
- **All inputs are validated before use:** names `^[a-z0-9][a-z0-9_-]{0,31}$`,
  refs `^[a-z0-9]{20}$`, tokens `^sbp_[A-Za-z0-9_]{20,}$`.
- **API calls are pinned to HTTPS** (`--proto =https`, 15 s timeout, `curl -q`
  so no `.curlrc`, `CURL_HOME` or `XDG_CONFIG_HOME` config can add `resolve`,
  `insecure` or a proxy). The API host (`api.supabase.com`) and keychain
  service name are hardcoded with no environment override at all.
- **Hardened against a hostile environment.** `bin/sbx` runs as `bash -p`, so
  `BASH_ENV`, `ENV`, `SHELLOPTS` (xtrace), `BASHOPTS`, `CDPATH` and
  env-exported functions are ignored; `security`, `curl` and `jq` are called by
  absolute path (`/usr/bin/...`); and the zsh wrapper strips those variables
  plus `PS4`, `CURL_HOME` and `XDG_CONFIG_HOME` before starting `sbx`.
- **A `.sbx` pin can only pick one of your own saved accounts.** Unknown or
  malformed names are ignored with a warning, and `sbx status` always tells you
  where the choice came from.
- **A linked project you don't own never gets someone else's token.** If
  `supabase/.temp/project-ref` names a project no saved account owns, `sbx`
  runs `supabase` untouched (with a notice) rather than falling back to the
  default account. The miss is cached; `sbx add` and `sbx refresh` clear it.

Know the limits: Keychain items created this way are readable by any process
running as your user without a prompt — the same as the Supabase CLI's own login
storage. If your user account is compromised, so are the tokens.

## Development

```sh
bash tests/run.sh   # pure-bash tests; `security` and `curl` are stubbed via PATH
bash -n bin/sbx
```

Design: `docs/superpowers/specs/2026-09-14-sbx-design.md`.
