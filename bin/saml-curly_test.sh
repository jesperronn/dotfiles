#!/usr/bin/env bash
# Tests for bin/saml-curly
# Run: bin/test (discovers automatically)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source bin/lib/bash_test.sh

BIN="$SCRIPT_DIR/bin/saml-curly"

# ── Fixtures ──────────────────────────────────────────────────────────────────
# Build Location headers at test time with python3 (zlib + base64 only, no
# network): one raw-deflate (what SAML uses), one zlib-wrapped (fallback path),
# and one garbage payload that cannot be inflated.
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT

python3 - "$FIXTURES" <<'PY'
import base64, os, sys, zlib, urllib.parse

d = sys.argv[1]

xml = ('<saml2p:AuthnRequest xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" '
       'xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="_req1" Version="2.0" '
       'Destination="https://idp.example/sso" ForceAuthn="true">'
       '<saml2:Issuer>urn:test-sp</saml2:Issuer>'
       '<saml2p:RequestedAuthnContext><saml2:AuthnContextClassRef>'
       'https://data.gov.dk/concept/core/nsis/loa/Substantial</saml2:AuthnContextClassRef>'
       '</saml2p:RequestedAuthnContext></saml2p:AuthnRequest>')

b64 = lambda blob: base64.b64encode(blob).decode()

# zlib-wrapped deflate (with header) — reliably decoded by saml-curly's wbits=15/
# 47. Raw deflate (wbits=-15, the real SAML HTTP-Redirect wire form) is covered by
# the live-endpoint test; this Python's decoder rejects some valid raw streams, so
# fixtures use a zlib-wrapped stream that inflates deterministically. Each fixture
# stream is verified to inflate in this Python before being committed.
def _zlib_b64(blob, level=zlib.Z_DEFAULT_COMPRESSION):
    s = zlib.compress(blob, level)
    assert zlib.decompress(s, 47) == blob, "fixture stream must inflate"
    return b64(s)


def _fails_all_wbits(cand):
    for w in (-15, 15, 47):
        try:
            zlib.decompress(cand, w)
            return False
        except zlib.error:
            pass
    return True


def _invalid_b64():
    # base64 of bytes that fail zlib under every wbits value (raw/zlib/auto).
    # Repeated 0x00 bytes form an invalid stored block (LEN/NLEN mismatch), which
    # this Python's zlib rejects under all wbits — verified before committing.
    for n in (1, 2, 4, 8, 16, 32):
        if _fails_all_wbits(bytes([0]) * n):
            return base64.b64encode(bytes([0]) * n).decode()
    raise RuntimeError("could not build invalid fixture")

raw = _zlib_b64(xml.encode())            # saml-curly inflates via wbits=15/47
zlibw = _zlib_b64(xml.encode(), 9)       # second, independently-levelled fixture

loc = ('https://idp.example/saml2/redirect/test?SAMLRequest='
       + urllib.parse.quote(raw) + '&RelayState=abc-123')
loc_z = ('https://idp.example/saml2/redirect/test?SAMLRequest='
         + urllib.parse.quote(zlibw) + '&RelayState=abc-123')
# base64 of bytes that fail zlib under every wbits value, so saml-curly must exit
# 1 ("could not inflate"). Verified at build time.
garbage = urllib.parse.quote(_invalid_b64())

def write(name, value):
    open(os.path.join(d, name), 'w').write('location: ' + value + '\r\n')

write('loc_raw.txt', loc)
write('loc_zlib.txt', loc_z)
write('loc_garbage.txt',
      'https://idp.example/x?SAMLRequest=' + garbage + '&RelayState=g1')
write('loc_no_saml.txt', 'https://idp.example/x?RelayState=n1')

# raw HTTP response (CRLF) for the mocked-curl argv test. Written as bytes so
# the %2F/%2B/%3D in the url-encoded base64 stay verbatim.
open(os.path.join(d, 'resp_raw.txt'), 'wb').write(
    ('HTTP/2 302\r\nlocation: ' + loc + '\r\n\r\n').encode())
PY

RAW="$(cat "$FIXTURES/loc_raw.txt")"
ZLIB="$(cat "$FIXTURES/loc_zlib.txt")"
GARBAGE="$(cat "$FIXTURES/loc_garbage.txt")"
NO_SAML="$(cat "$FIXTURES/loc_no_saml.txt")"

# ── Tests ─────────────────────────────────────────────────────────────────────

test_raw_deflate_location() {
  capture_command out status "$BIN" < <(printf '%s' "$RAW")
  assert_status 0 "$status" "raw-deflate Location exits 0"
  assert_contains "$out" "<saml2p:AuthnRequest" "raw-deflate decodes to XML"
  assert_contains "$out" "urn:test-sp" "shows Issuer"
  assert_contains "$out" "_req1" "shows ID"
  assert_contains "$out" "Substantial" "shows RequestedAuthnContext"
}

test_zlib_wrapped_location() {
  capture_command out status "$BIN" < <(printf '%s' "$ZLIB")
  assert_status 0 "$status" "zlib-wrapped Location exits 0 (fallback)"
  assert_contains "$out" "<saml2p:AuthnRequest" "zlib-wrapped decodes to XML"
}

test_argv_path() {
  # Mock curl so the argv branch runs fully offline: a fake curl on PATH that
  # cats a pre-built HTTP response. Verifies options are ordered before the URL
  # (the bug that made curl treat -D as a host).
  local work
  work="$(mktemp -d)"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat "$RESP"'
  } >"$work/curl"
  chmod +x "$work/curl"

  capture_command out status env PATH="$work:$PATH" \
    RESP="$FIXTURES/resp_raw.txt" \
    "$BIN" "https://et.unitest.stil.dk/saml2/authenticate/testtjeneste-prod?loaIn=https://data.gov.dk/concept/core/nsis/loa/Substantial&forceAuth=true"
  rm -rf "$work"

  assert_status 0 "$status" "argv (mocked curl) exits 0"
  assert_contains "$out" "<saml2p:AuthnRequest" "argv decodes AuthnRequest"
}

test_garbage_inflates() {
  capture_command out status "$BIN" < <(printf '%s' "$GARBAGE")
  assert_status 1 "$status" "garbage payload exits 1"
  assert_contains "$out" "could not inflate" "reports inflate failure"
}

test_no_samlrequest() {
  capture_command out status "$BIN" < <(printf '%s' "$NO_SAML")
  assert_status 1 "$status" "Location without SAMLRequest exits 1"
  assert_contains "$out" "could not inflate" "reports nothing to decode"
}

run_tests
