#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPG_CHECK_BIN="$DOTFILES_ROOT/bin/gpg-check"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

STUB_DIR="$(mktemp -d)"

cleanup_test_tmp() {
  rm -rf "$STUB_DIR"
}
trap 'cleanup_test_tmp' EXIT

# Stub gpg, op and gpgconf first on PATH so the real ones (and any 1Password
# prompt) are never reached. gpg records its args and answers --list-secret-keys
# from a fixture; op records its args and prints a fake passphrase.
mkdir -p "$STUB_DIR/bin"
cat > "$STUB_DIR/bin/gpg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--list-secret-keys"* ]]; then
  cat <<'KEYS'
sec:u:2048:1:B557F2DD740B2A3C:1516838400:::u:::scESC:::+:::23::0:
fpr:::::::::ABCDEF0123456789ABCDEF01B557F2DD740B2A3C:
uid:u::::1516838400::0123456789ABCDEF0123456789ABCDEF01234567::Jesper Rønn-Jensen <jrj@nine.dk>::::::::::0:
KEYS
  exit 0
fi
echo "$*" > "$STUB_DIR/gpg_args"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == "--status-file" ]] && status_file="${args[i + 1]}"
done
if [[ "${GPG_STUB_STATUS:-0}" == "0" ]]; then
  echo "[GNUPG:] SIG_CREATED C 1 8 01 1700000000 ABCDEF0123456789ABCDEF01B557F2DD740B2A3C" > "$status_file"
fi
exit "${GPG_STUB_STATUS:-0}"
EOF
cat > "$STUB_DIR/bin/op" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/op_args"
echo "fake-passphrase"
exit "${OP_STUB_STATUS:-0}"
EOF
cat > "$STUB_DIR/bin/gpgconf" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/gpgconf_args"
EOF
chmod +x "$STUB_DIR/bin/"*
export STUB_DIR
export PATH="$STUB_DIR/bin:$PATH"

reset_stubs() {
  rm -f "$STUB_DIR/gpg_args" "$STUB_DIR/op_args" "$STUB_DIR/gpgconf_args"
}

stub_args() {
  cat "$STUB_DIR/$1" 2> /dev/null || echo "(not called)"
}

test_default_uses_1password() {
  local output=""
  local status=0

  reset_stubs
  capture_command output status "$GPG_CHECK_BIN"
  assert_status "0" "$status" "gpg-check succeeds"
  assert_contains "$output" "Fetching passphrase from 1Password (GPG_SIGN_PASSPHRASE)..." "hints that 1Password will be asked"
  assert_contains "$output" "[PASS] Signed test message with Jesper Rønn-Jensen <jrj@nine.dk> (RSA 2048, B557F2DD740B2A3C)" "shows the signing key"
  assert_eq "item get GPG_SIGN_PASSPHRASE --fields label=credential --reveal" "$(stub_args op_args)" "reads the passphrase from 1Password"
  assert_contains "$(stub_args gpg_args)" "--pinentry-mode loopback --passphrase-fd 3" "gives gpg the passphrase via loopback pinentry"
}

test_password_mode_skips_1password() {
  local output=""
  local status=0

  reset_stubs
  capture_command output status "$GPG_CHECK_BIN" --pw
  assert_status "0" "$status" "gpg-check --pw succeeds"
  assert_eq "(not called)" "$(stub_args op_args)" "--pw does not call op"
  assert_not_contains "$(stub_args gpg_args)" "loopback" "--pw lets gpg ask for the passphrase"
}

test_gpg_failure_is_propagated() {
  local output=""
  local status=0

  reset_stubs
  GPG_STUB_STATUS=2 capture_command output status "$GPG_CHECK_BIN"
  assert_status "2" "$status" "returns gpg's failure status"
  assert_contains "$output" "[FAIL] Signing test message failed (exit 2)" "reports the signing failure"
}

test_op_failure_stops_before_gpg() {
  local output=""
  local status=0

  reset_stubs
  OP_STUB_STATUS=1 capture_command output status "$GPG_CHECK_BIN"
  assert_status "1" "$status" "fails when op fails"
  assert_contains "$output" "[FAIL] Could not fetch passphrase from 1Password" "reports the op failure"
  assert_eq "(not called)" "$(stub_args gpg_args)" "gpg is not called when op fails"
}

test_clear_only_reloads_agent() {
  local output=""
  local status=0

  reset_stubs
  capture_command output status "$GPG_CHECK_BIN" --clear
  assert_status "0" "$status" "gpg-check --clear succeeds"
  assert_eq "--reload gpg-agent" "$(stub_args gpgconf_args)" "--clear reloads gpg-agent"
  assert_eq "(not called)" "$(stub_args gpg_args)" "--clear alone does not sign"
}

test_conflicting_modes_are_rejected() {
  local output=""
  local status=0

  capture_command output status "$GPG_CHECK_BIN" --op --pw
  assert_status "2" "$status" "rejects --op together with --pw"
  assert_contains "$output" "usage:" "prints usage"
}

run_tests "$@"
