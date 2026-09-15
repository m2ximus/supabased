# sbx — per-folder Supabase CLI accounts

## Problem
The Supabase CLI holds one login at a time. The user works across many Supabase
accounts across many project folders and wants `supabase ...` to always use the right account
for the folder they are in, with no manual switching.

## Solution
A single bash CLI `sbx` plus a zsh shell function that wraps `supabase`.

- Tokens for N accounts are stored in the macOS login Keychain
  (service `sbx-supabase`, account = sbx name).
- `supabase ...` in zsh becomes `sbx exec -- supabase ...`, which resolves the
  account for `$PWD` and runs the real binary with `SUPABASE_ACCESS_TOKEN` set
  **only for that child process**.

## Resolution order (walk up from $PWD to /; first hit wins per directory)
1. `.sbx` file (first line = account name) — explicit pin.
2. `supabase/.temp/project-ref` — look up owning account in cache
   (`$SBX_HOME/ref-cache`), else query each account's `GET /v1/projects`
   and cache the owner.
3. `$SBX_HOME/default` account.
4. None → run `supabase` untouched (its own login applies), notice on stderr.

If the user already exported `SUPABASE_ACCESS_TOKEN`, `sbx exec` passes it
through unchanged (explicit override).

## Commands
`add <name>`, `remove <name>`, `list [--projects]`, `default <name>`,
`pin <name>`, `which [dir]`, `status`, `exec -- cmd...`, `refresh`,
`init zsh`, `help`.

## Security requirements (non-negotiable)
- S1 Tokens never touch disk outside Keychain; never appear in argv of any
  process (`ps`-visible). Keychain writes use `security -i` fed via stdin;
  API calls pass the header via `curl -H @-`.
- S2 Tokens are read with `read -s` (tty) or stdin — never as CLI args.
- S3 Token is never exported into the interactive shell; only the `supabase`
  child process receives it.
- S4 `$SBX_HOME` (default `~/.config/sbx`) is mode 700, files 600 (`umask 077`).
  It contains only names, refs and mappings — no secrets.
- S5 All names validated `^[a-z0-9][a-z0-9_-]{0,31}$`, refs `^[a-z0-9]{20}$`,
  tokens `^sbp_[A-Za-z0-9_]{20,}$` before use (prevents injection into the
  `security -i` command stream and config files).
- S6 API calls: `--proto =https`, `--max-time 15`, `-fsS`.
- S7 A `.sbx` pin can only select among the user's own saved accounts; unknown
  names are rejected with a warning. `status` always shows the source.
- S8 Tokens are never printed or logged, including in errors and `set -x`-free code.

## Out of scope
Menu bar/web UI, non-macOS keychains, managing `supabase link`.

## Testing
Pure-bash test runner (`tests/run.sh`), stubbing `security` and `curl` via PATH.
Bash 3.2 compatible (macOS system bash; no associative arrays, no `mapfile`).
