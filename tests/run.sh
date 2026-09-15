#!/bin/bash
# sbx test runner — pure bash 3.2, stubs `security` and `curl` via PATH.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)

setup() {
  T=$(mktemp -d)
  export SBX_HOME="$T/home" STUB_KC="$T/kc" STUB_API="$T/api" STUB_ARGV_LOG="$T/argv.log"
  mkdir -p "$STUB_KC" "$STUB_API"
  : > "$STUB_ARGV_LOG"
  unset SUPABASE_ACCESS_TOKEN SBX_QUIET SBX_API SBX_SERVICE SBX_TEST CURL_HOME XDG_CONFIG_HOME BASH_ENV
  # The shipped script calls /usr/bin/security and /usr/bin/curl by absolute path and
  # honours no env override, so tests run a per-run copy with those paths swapped for stubs.
  sed -e 's#/usr/bin/security#'"$ROOT"'/tests/stubs/security#g' \
      -e 's#/usr/bin/curl#'"$ROOT"'/tests/stubs/curl#g' "$ROOT/bin/sbx" > "$T/sbx"
  chmod +x "$T/sbx"
  SBX="$T/sbx"
  KC="$STUB_KC/sbx-supabase"   # stub item path prefix: real service name, stub store
  cd "$T"   # isolate from stray .sbx / project-ref above the repo
}
assert_eq() { [ "$1" = "$2" ] || { echo "  expected [$2] got [$1]"; return 1; }; }
assert_contains() { case "$1" in *"$2"*) ;; *) echo "  [$1] lacks [$2]"; return 1;; esac; }

# ---------- Task 1 ----------
t_help_works() {
  out=$($SBX help) && assert_contains "$out" "sbx add"
}
t_unknown_cmd_fails() {
  err=$($SBX bogus 2>&1 >/dev/null); rc=$?
  [ "$rc" = 1 ] && assert_contains "$err" "sbx:"
}

# ---------- Task 2: account store ----------
TOK="sbp_""aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # split so secret scanners ignore this fake token
TOK2="sbp_""bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"  # split so secret scanners ignore this fake token
# add NAME TOKEN JSON — write API fixture and pipe token into `sbx add`.
add() { printf '%s' "$3" > "$STUB_API/$2.json"; echo "$2" | $SBX add "$1" >/dev/null; }

t_add_stores_in_keychain_not_disk() {
  echo '[{"id":"abcdefghijklmnopqrst","name":"App"}]' > "$STUB_API/$TOK.json"
  out=$(echo "$TOK" | $SBX add work) &&
  assert_contains "$out" "added work (1 projects)" &&
  assert_eq "$(cat "$KC.work")" "$TOK" &&
  ! grep -rq "$TOK" "$SBX_HOME" &&
  ! grep -q "$TOK" "$STUB_ARGV_LOG" &&        # S1: never in argv
  assert_eq "$(cat "$SBX_HOME/default")" work &&
  assert_eq "$(cat "$SBX_HOME/accounts")" work &&
  assert_eq "$(stat -f %Lp "$SBX_HOME")" 700 &&
  assert_eq "$(stat -f %Lp "$SBX_HOME/accounts")" 600
}
t_add_rejects_bad_token() { ! echo "nope" | $SBX add work 2>/dev/null && [ ! -e "$KC.work" ]; }
t_add_rejects_token_failing_api() { ! echo "$TOK" | $SBX add work 2>/dev/null && [ ! -e "$KC.work" ]; }
t_add_rejects_bad_name() { echo '[]' > "$STUB_API/$TOK.json"; ! echo "$TOK" | $SBX add 'x;rm -rf' 2>/dev/null && [ ! -e "$SBX_HOME/accounts" ]; }
t_add_rejects_token_as_arg() { echo '[]' > "$STUB_API/$TOK.json"; ! $SBX add work "$TOK" </dev/null 2>/dev/null && ! grep -q "$TOK" "$STUB_ARGV_LOG"; }
t_add_is_idempotent() {
  add work "$TOK" '[]' && add work "$TOK2" '[]' &&
  assert_eq "$(cat "$SBX_HOME/accounts")" work &&
  assert_eq "$(cat "$KC.work")" "$TOK2"
}
t_error_output_never_contains_token() {
  out=$(echo "sbp_bad!token" | $SBX add work 2>&1); ! assert_contains "$out" "sbp_bad" >/dev/null
}
t_list_marks_default() {
  add work "$TOK" '[]' && add personal "$TOK2" '[]' &&
  out=$($SBX list) &&
  assert_contains "$out" "work *" && assert_contains "$out" "personal" && ! assert_contains "$out" "personal *" >/dev/null
}
t_list_projects() {
  add work "$TOK" '[{"id":"abcdefghijklmnopqrst","name":"App"}]' &&
  out=$($SBX list --projects) &&
  assert_contains "$out" "$(printf '  abcdefghijklmnopqrst  App')" && ! assert_contains "$out" "sbp_" >/dev/null
}
t_remove_cleans_up() {
  add work "$TOK" '[]' && add personal "$TOK2" '[]' &&
  echo "abcdefghijklmnopqrst work" > "$SBX_HOME/ref-cache" &&
  echo "zzzzzzzzzzzzzzzzzzzz personal" >> "$SBX_HOME/ref-cache" &&
  $SBX remove work &&
  [ ! -e "$KC.work" ] && ! grep -q work "$SBX_HOME/accounts" &&
  ! grep -q work "$SBX_HOME/ref-cache" && grep -q personal "$SBX_HOME/ref-cache" &&
  [ ! -s "$SBX_HOME/default" ] || [ "$(cat "$SBX_HOME/default")" != work ]
}
t_remove_unknown_fails() { ! $SBX remove ghost 2>/dev/null; }
t_default_requires_existing() { add work "$TOK" '[]'; ! $SBX default ghost 2>/dev/null; }
t_default_sets() {
  add work "$TOK" '[]' && add personal "$TOK2" '[]' && $SBX default personal &&
  assert_eq "$(cat "$SBX_HOME/default")" personal
}

# ---------- Task 3: resolver ----------
REF=abcdefghijklmnopqrst
REFJSON='[{"id":"abcdefghijklmnopqrst","name":"Client App"}]'
mkref() { mkdir -p "$1/supabase/.temp"; echo "$2" > "$1/supabase/.temp/project-ref"; }

t_which_uses_default() {
  add work "$TOK" '[]' && mkdir "$T/p" &&
  assert_eq "$($SBX which "$T/p")" "$(printf 'work\tdefault\t-')"
}
t_which_ref_lookup_and_cache() {
  add work "$TOK" '[]' && add client "$TOK2" "$REFJSON" &&
  mkref "$T/p" "$REF" && mkdir -p "$T/p/sub" &&
  assert_eq "$($SBX which "$T/p/sub")" "$(printf 'client\tref\t%s' "$REF")" &&
  grep -q "^$REF client$" "$SBX_HOME/ref-cache" &&
  rm "$STUB_API"/*.json &&
  assert_eq "$($SBX which "$T/p")" "$(printf 'client\tref\t%s' "$REF")"   # served from cache
}
t_refresh_clears_cache() {
  add client "$TOK2" "$REFJSON" && mkref "$T/p" "$REF" &&
  $SBX which "$T/p" >/dev/null && [ -e "$SBX_HOME/ref-cache" ] &&
  $SBX refresh && [ ! -e "$SBX_HOME/ref-cache" ]
}
t_pin_beats_ref() {
  add work "$TOK" '[]' && add client "$TOK2" "$REFJSON" && mkref "$T/p" "$REF" &&
  (cd "$T/p" && $SBX pin work >/dev/null) &&
  assert_eq "$(cat "$T/p/.sbx")" work &&
  assert_contains "$($SBX which "$T/p")" "$(printf 'work\tpin:%s/.sbx\t%s' "$T/p" "$REF")"
}
t_pin_requires_existing() { ! $SBX pin ghost 2>/dev/null && [ ! -e "$T/.sbx" ]; }
t_pin_unknown_account_ignored() {
  add work "$TOK" '[]' && mkdir "$T/p" && echo ghost > "$T/p/.sbx" &&
  out=$($SBX which "$T/p" 2>&1) &&
  assert_contains "$out" "ignoring" && assert_contains "$out" "$(printf 'work\tdefault')"
}
t_pin_invalid_name_ignored() {
  add work "$TOK" '[]' && mkdir "$T/p" && printf 'x;rm -rf /\n' > "$T/p/.sbx" &&
  out=$($SBX which "$T/p" 2>&1) &&
  assert_contains "$out" "ignoring" && assert_contains "$out" "$(printf 'work\tdefault')"
}
t_unowned_ref_does_not_fall_back_to_default() {
  add work "$TOK" '[]' && mkref "$T/p" "$REF" &&
  err=$($SBX which "$T/p" 2>&1 >/dev/null); rc=$?
  [ "$rc" = 1 ] && assert_contains "$err" "no saved account owns" &&
  grep -q "^$REF -$" "$SBX_HOME/ref-cache" &&              # negative-cached
  : > "$STUB_ARGV_LOG" &&
  ! $SBX which "$T/p" 2>/dev/null &&
  ! grep -q '^curl' "$STUB_ARGV_LOG" &&                     # second call hits no API
  cd "$T/p" &&
  out=$($SBX exec -- sh -c 'printf %s "${SUPABASE_ACCESS_TOKEN:-none}"' 2>/dev/null) &&
  assert_eq "$out" none                                     # runs untouched, no token
}
t_add_clears_negative_cache() {
  add work "$TOK" '[]' && mkref "$T/p" "$REF" &&
  ( $SBX which "$T/p" >/dev/null 2>&1; true ) && grep -q "^$REF -$" "$SBX_HOME/ref-cache" &&
  add client "$TOK2" "$REFJSON" &&
  assert_eq "$($SBX which "$T/p" 2>/dev/null)" "$(printf 'client\tref\t%s' "$REF")"
}
t_which_none() { mkdir "$T/p"; ! $SBX which "$T/p" 2>/dev/null; }
t_which_output_never_contains_token() {
  add client "$TOK2" "$REFJSON" && mkref "$T/p" "$REF" &&
  out=$($SBX which "$T/p" 2>&1) && ! assert_contains "$out" "sbp_" >/dev/null &&
  ! grep -q "sbp_" "$STUB_ARGV_LOG"
}
# ---------- env-hardening regressions ----------
t_api_override_ignored_even_with_test_flag() {
  add client "$TOK2" "$REFJSON" && mkref "$T/p" "$REF" && : > "$STUB_ARGV_LOG" &&
  ( export SBX_TEST=1 SBX_API=https://evil.example; $SBX which "$T/p" >/dev/null 2>&1; true ) &&
  grep -q 'curl .*https://api\.supabase\.com/v1/projects' "$STUB_ARGV_LOG" &&
  ! grep -q evil "$STUB_ARGV_LOG"
}
t_service_override_ignored_even_with_test_flag() {
  add client "$TOK2" "$REFJSON" && mkref "$T/p" "$REF" && : > "$STUB_ARGV_LOG" &&
  ( export SBX_TEST=1 SBX_SERVICE=evil-svc; $SBX which "$T/p" >/dev/null 2>&1; true ) &&
  ! grep -q 'evil-svc' "$STUB_ARGV_LOG" && grep -q -- '-s sbx-supabase' "$STUB_ARGV_LOG"
}
t_curl_ignores_curlrc() {
  mkdir "$T/ch" && printf 'resolve=api.supabase.com:443:127.0.0.1\ninsecure\n' > "$T/ch/.curlrc" &&
  printf '%s' '[]' > "$STUB_API/$TOK.json" &&
  echo "$TOK" | CURL_HOME="$T/ch" XDG_CONFIG_HOME="$T/ch" $SBX add work >/dev/null &&
  grep -q '^curl -q ' "$STUB_ARGV_LOG" && ! grep '^curl' "$STUB_ARGV_LOG" | grep -qv '^curl -q '
}
t_shellopts_xtrace_does_not_leak_token() {
  add work "$TOK" '[]' && mkdir "$T/p" && cd "$T/p" &&
  out=$(env SHELLOPTS=xtrace PS4='+leak: ' "$SBX" exec -- sh -c 'exit 0' 2>&1); rc=$?
  [ "$rc" = 0 ] && ! assert_contains "$out" "sbp_" >/dev/null && ! assert_contains "$out" "+leak" >/dev/null
}
t_bash_env_cannot_hijack() {
  add work "$TOK" '[]' && mkdir "$T/p" && cd "$T/p" &&
  printf 'echo PWNED >&2\nsecurity() { echo PWNED-fn >&2; }\n' > "$T/evil.sh" &&
  out=$(env BASH_ENV="$T/evil.sh" ENV="$T/evil.sh" SBX_QUIET=1 "$SBX" exec -- sh -c 'printf %s "$SUPABASE_ACCESS_TOKEN"' 2>&1) &&
  assert_eq "$out" "$TOK"
}
t_zsh_wrapper_passes_args_stdin_exit() {
  command -v zsh >/dev/null || return 0
  add work "$TOK" '[]' && mkdir "$T/p" && cd "$T/p" &&
  mkdir "$T/bin" && ln -s "$SBX" "$T/bin/sbx" &&
  out=$(printf 'in\n' | PATH="$T/bin:$PATH" SBX_QUIET=1 zsh -c "$($SBX init zsh); supabase() { command env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u PS4 -u CURL_HOME -u XDG_CONFIG_HOME sbx exec -- sh \"\$@\"; }; supabase -c 'read l; printf \"%s|%s|%s\" \"\$l\" \"\$1\" \"\$SUPABASE_ACCESS_TOKEN\"; exit 3' x 'a b'; echo \" rc=\$?\"") &&
  assert_eq "$out" "in|a b|$TOK rc=3"
}

# ---------- Task 4: exec / status / init ----------
t_exec_injects_token_into_child_only() {
  add work "$TOK" '[]' && mkdir "$T/p" && cd "$T/p" &&
  out=$(SBX_QUIET=1 $SBX exec -- sh -c 'printf %s "$SUPABASE_ACCESS_TOKEN"') &&
  assert_eq "$out" "$TOK" &&
  ! grep -q "$TOK" "$STUB_ARGV_LOG" &&
  [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]
}
t_exec_announces_account_on_stderr() {
  add work "$TOK" '[]' && mkdir "$T/p" && cd "$T/p" &&
  err=$($SBX exec -- true 2>&1) && assert_contains "$err" "work (default)" &&
  err=$(SBX_QUIET=1 $SBX exec -- true 2>&1) && assert_eq "$err" ""
}
t_exec_respects_explicit_env() {
  add work "$TOK" '[]' &&
  out=$(SUPABASE_ACCESS_TOKEN=sbp_explicit SBX_QUIET=1 $SBX exec -- sh -c 'printf %s "$SUPABASE_ACCESS_TOKEN"') &&
  assert_eq "$out" sbp_explicit
}
t_exec_no_account_runs_untouched() {
  mkdir "$T/p" && cd "$T/p" &&
  out=$($SBX exec -- sh -c 'printf %s "${SUPABASE_ACCESS_TOKEN:-none}"' 2>"$T/err") &&
  assert_eq "$out" none && assert_contains "$(cat "$T/err")" "no account for this folder"
}
t_exec_keychain_failure_dies_without_token() {
  add work "$TOK" '[]' && rm "$KC.work" &&
  ! out=$($SBX exec -- true 2>&1) && assert_contains "$out" "keychain lookup failed for work"
}
t_exec_requires_separator() { add work "$TOK" '[]'; ! $SBX exec true 2>/dev/null && ! $SBX exec -- 2>/dev/null; }
t_exec_passes_exit_status() { add work "$TOK" '[]'; SBX_QUIET=1 $SBX exec -- sh -c 'exit 7'; [ $? = 7 ]; }
t_status_never_prints_token() {
  add work "$TOK" '[]' && out=$($SBX status 2>&1) &&
  assert_contains "$out" "account: work" && assert_contains "$out" "source: default" &&
  assert_contains "$out" "project: -" && ! assert_contains "$out" "sbp_" >/dev/null
}
t_status_no_account() { out=$($SBX status 2>&1); assert_contains "$out" "no account for this folder"; }
t_init_zsh() {
  out=$($SBX init zsh) &&
  assert_contains "$out" 'supabase() { command env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u PS4 -u CURL_HOME -u XDG_CONFIG_HOME sbx exec -- supabase "$@"; }' &&
  assert_contains "$out" '# sbx: per-folder Supabase accounts'
}
t_init_other_shell_fails() { ! $SBX init fish 2>/dev/null; }

# ---------- runner ----------
pass=0; fail=0
for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
  if ( setup && "$t" ); then
    echo "PASS $t"; pass=$((pass+1))
  else
    echo "FAIL $t"; fail=$((fail+1))
  fi
done
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
