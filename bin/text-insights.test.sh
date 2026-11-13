#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/bin/lib/bash_test.sh"
SCRIPT="$ROOT_DIR/bin/text-insights"
TEST_TMP="$(mktemp -d)"
cleanup_test_tmp() { rm -rf "$TEST_TMP"; }
trap 'cleanup_test_tmp' EXIT

assert_eq 'length: 8, alpha: `estT`, numeric: `1234`, special: no, whitespace: no
`T******4`' "$(printf 'Test1234' | "$SCRIPT")" 'example and eight-character boundary'
assert_contains "$(printf 'Test12345' | "$SCRIPT")" '`T****2345`' 'nine-character boundary'
assert_contains "$(printf 'aabb2211' | "$SCRIPT")" 'alpha: `ab`, numeric: `12`' 'unique sorted characters'
assert_eq 'length: 0, alpha: ``, numeric: ``, special: no, whitespace: no
``' "$(printf '' | "$SCRIPT")" 'empty stdin'
assert_contains "$(printf 'x' | "$SCRIPT")" '`x`' 'single character'
assert_contains "$(printf 'xy' | "$SCRIPT")" '`xy`' 'two characters'
assert_contains "$(printf 'a !\t\n' | "$SCRIPT")" 'length: 5, alpha: `a`, numeric: ``, special: `!`, whitespace: yes' 'whitespace preserved and special characters detected'
assert_contains "$(printf 'æøå123😀z' | "$SCRIPT")" 'length: 8' 'Unicode characters counted rather than bytes'
cat > "$TEST_TMP/pbpaste" <<'STUB'
#!/usr/bin/env bash
printf 'Test1234'
STUB
chmod +x "$TEST_TMP/pbpaste"
assert_eq "$(printf 'Test1234' | "$SCRIPT")" "$(PATH="$TEST_TMP:$PATH" "$SCRIPT" --clipboard)" 'clipboard input uses stub'
assert_contains "$("$SCRIPT" --help)" 'stdin' 'help documents input'
status=0
"$SCRIPT" --unknown >"$TEST_TMP/error" 2>&1 || status=$?
assert_eq '2' "$status" 'unknown arguments rejected'

assert_contains "$(printf 'a@!@# !' | "$SCRIPT")" 'special: `!#@`' 'special characters are shown once in sorted order'

assert_contains "$(printf 'a!`@' | "$SCRIPT")" 'special: `` !@` ``' 'backtick uses padded double-backtick delimiters'
assert_contains "$(printf '`' | "$SCRIPT")" 'special: `` ` ``' 'single backtick is displayed safely'
assert_contains "$(printf '`' | "$SCRIPT")" $'\n`` ` ``' 'masked output also safely displays a backtick'
assert_contains "$(printf '``' | "$SCRIPT")" $'\n``` `` ```' 'masked output handles consecutive backticks'
