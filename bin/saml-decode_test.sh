#!/usr/bin/env bash
# Tests for bin/saml-decode
# Run: bin/test (discovers automatically)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source bin/lib/bash_test.sh

BIN="$SCRIPT_DIR/bin/saml-decode"

# ── Fixtures ──────────────────────────────────────────────────────────────────
# Generate everything at test time with python3 (cryptography is available).
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT

python3 - "$FIXTURES" <<'PY'
import base64, os, sys, zlib, urllib.parse
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding as asym_padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

d = sys.argv[1]

def b64n(n):
    return base64.b64encode(n.to_bytes((n.bit_length() + 7) // 8, 'big')).decode()

# --- base XML (a real AuthnRequest) ---
xml = ('<saml2p:AuthnRequest xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" '
       'xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="_req1" Version="2.0">'
       '<saml2:Issuer>urn:test-sp</saml2:Issuer>'
       '<saml2p:Destination>https://idp.example/sso</saml2p:Destination>'
       '</saml2p:AuthnRequest>')

# redirect binding: zlib -> base64 -> url-encoded
compressed = zlib.compress(xml.encode())
b64 = base64.b64encode(compressed).decode()
open(os.path.join(d, 'redirect.txt'), 'w').write(
    'https://idp.example/saml?SAMLRequest=' + urllib.parse.quote(b64) +
    '&RelayState=abc-123&SigAlg=http%3A%2F%2Fwww.w3.org%2F2001%2F04%2Fxmldsig-more%23rsa-sha256&Signature=Qm9nZXNlcmZ1bm5')

# bare base64 (no url-encoding)
open(os.path.join(d, 'bare.txt'), 'w').write(b64)

# POST binding: xml -> quote -> base64 (no compression)
post = base64.b64encode(urllib.parse.quote(xml).encode()).decode()
open(os.path.join(d, 'post.txt'), 'w').write(post)

# --- encrypted fixture (SAMLResponse with EncryptedAssertion) ---
inner = ('<saml2p:Response xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" '
         'xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="_resp1">'
         '<saml2:Issuer>urn:inner-assertion</saml2:Issuer>'
         '</saml2p:Response>')

priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pem = priv.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption())
open(os.path.join(d, 'key.pem'), 'wb').write(pem)

mod = priv.public_key().public_numbers().n
exp = priv.public_key().public_numbers().e

aes_key = os.urandom(32)  # AES-256
iv = os.urandom(16)
cipher = Cipher(algorithms.AES(aes_key), modes.CBC(iv))
enc = cipher.encryptor()
pad_len = 16 - (len(inner.encode()) % 16)
ct = enc.update(inner.encode() + bytes([pad_len]) * pad_len) + enc.finalize()
ciphertext = iv + ct  # prepend IV

# wrap AES key with the SP public cert (IdP -> SP)
wrapped = priv.public_key().encrypt(aes_key,
    asym_padding.OAEP(mgf=asym_padding.MGF1(algorithm=hashes.SHA1()),
                      algorithm=hashes.SHA1(), label=None))

enc_data = ('<saml2:EncryptedData><saml2:CipherData><saml2:CipherValue>'
            + base64.b64encode(ciphertext).decode() + '</saml2:CipherValue></saml2:CipherData></saml2:EncryptedData>')
enc_key = ('<saml2:EncryptedKey><saml2:CipherData><saml2:EncryptedValue>'
           + base64.b64encode(wrapped).decode() + '</saml2:EncryptedValue></saml2:CipherData>'
           '<saml2:KeyInfo><saml2:RSAKeyValue><saml2:Modulus>' + b64n(mod) + '</saml2:Modulus>'
           '<saml2:Exponent>' + b64n(exp) + '</saml2:Exponent></saml2:RSAKeyValue></saml2:KeyInfo></saml2:EncryptedKey>')

enc_doc = ('<saml2p:Response xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" '
           'xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="_resp1">'
           '<saml2:EncryptedAssertion>' + enc_data + enc_key + '</saml2:EncryptedAssertion></saml2p:Response>')

# wrap encrypted doc like redirect: zlib -> base64 -> url-encoded, param SAMLResponse
enc_b64 = base64.b64encode(zlib.compress(enc_doc.encode())).decode()
open(os.path.join(d, 'enc_url.txt'), 'w').write(
    'https://idp.example/saml?SAMLResponse=' + urllib.parse.quote(enc_b64) + '&RelayState=r1')
PY

REDIRECT="$(cat "$FIXTURES/redirect.txt")"
BARE="$(cat "$FIXTURES/bare.txt")"
POST="$(cat "$FIXTURES/post.txt")"
ENC_URL="$(cat "$FIXTURES/enc_url.txt")"
KEY="$FIXTURES/key.pem"

# ── Tests ─────────────────────────────────────────────────────────────────────

test_redirect_url() {
  capture_command out status "$BIN" "$REDIRECT"
  assert_status 0 "$status" "redirect url exits 0"
  assert_contains "$out" "Decoded SAMLRequest (decompressed)" "redirect marks decompressed"
  assert_contains "$out" "URL: https://idp.example/saml" "redirect echoes URL"
  assert_contains "$out" "urn:test-sp" "redirect shows Issuer"
  assert_contains "$out" "_req1" "redirect shows ID"
  assert_contains "$out" "RelayState: abc-123" "redirect echoes RelayState"
  assert_contains "$out" "SigAlg: http://www.w3.org/2001/04/xmldsig-more#rsa-sha256" "redirect echoes SigAlg"
  assert_contains "$out" "Signature: Qm9nZXNlcmZ1bm5" "redirect echoes Signature"
}

test_bare_base64() {
  printf '%s' "$BARE" >"$FIXTURES/bare_in.txt"
  capture_command out status "$BIN" <"$FIXTURES/bare_in.txt"
  assert_status 0 "$status" "bare base64 exits 0"
  assert_contains "$out" "Decoded SAMLRequest (decompressed)" "bare marks decompressed"
  assert_contains "$out" "urn:test-sp" "bare shows Issuer"
}

test_post_binding() {
  printf '%s' "$POST" >"$FIXTURES/post_in.txt"
  capture_command out status "$BIN" <"$FIXTURES/post_in.txt"
  assert_status 0 "$status" "post binding exits 0"
  assert_contains "$out" "Decoded SAMLRequest (urldecode)" "post marks urldecode"
  assert_contains "$out" "urn:test-sp" "post shows Issuer"
}

test_xml_flag() {
  capture_command out status "$BIN" --xml "$REDIRECT"
  assert_status 0 "$status" "xml flag exits 0"
  assert_contains "$out" "<saml2p:AuthnRequest" "xml shows raw XML root tag"
  assert_contains "$out" "urn:test-sp" "xml shows Issuer"
}

test_color_output() {
  # Representative AuthnRequest exercising dim/bold styling rules. Generate a
  # redirect URL inline (URL-encoded) and pass it directly as argv.
  local url
  url="$(
    python3 - <<'PY'
import base64, zlib, urllib.parse
xml = ('<saml2p:AuthnRequest xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" '
       'xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="_req1" Version="2.0" '
       'ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" '
       'InResponseTo="_c1">'
       '<saml2:Issuer>urn:test-sp</saml2:Issuer>'
       '<saml2p:Destination>https://idp.example/sso</saml2p:Destination>'
       '<saml2p:Signature>LS0tQkVHSU5TRFNFRA==</saml2p:Signature>'
       '</saml2p:AuthnRequest>')
b64 = base64.b64encode(zlib.compress(xml.encode())).decode()
print("https://idp.example/saml?SAMLRequest=" + urllib.parse.quote(b64) + "&RelayState=abc-123")
PY
  )"
  capture_command out status env SAML_DECODE_COLOR=1 "$BIN" "$url"
  assert_status 0 "$status" "color output exits 0"
  assert_contains "$out" $'\x1b[' "emits ANSI escape codes"
  assert_contains "$out" $'\x1b[1m\x1b[36mAuthnRequest\x1b[0m' "AuthnRequest header bold cyan"
  assert_contains "$out" $'\x1b[1murn:test-sp\x1b[0m' "Issuer value bold"
  assert_contains "$out" $'\x1b[2mLS0tQkVHSU5TRFNFRA==\x1b[0m' "Signature value dimmed"
  assert_contains "$out" $'\x1b[2m_req1\x1b[0m' "ID value dimmed"
}

test_attributes_one_per_line() {
  # AuthnRequest attributes render one per line, indented beneath the header,
  # not inline as "(ID=..., Version=..., ...)".
  local url
  url="$(
    python3 - <<'PY'
import base64, zlib, urllib.parse
xml = ('<saml2p:AuthnRequest xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" '
       'xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="_req1" Version="2.0" '
       'ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" '
       'InResponseTo="_c1">'
       '<saml2:Issuer>urn:test-sp</saml2:Issuer>'
       '</saml2p:AuthnRequest>')
b64 = base64.b64encode(zlib.compress(xml.encode())).decode()
print("https://idp.example/saml?SAMLRequest=" + urllib.parse.quote(b64))
PY
  )"
  capture_command out status "$BIN" "$url"
  assert_status 0 "$status" "attribute expansion exits 0"
  assert_contains "$out" "ID _req1" "ID renders one per line (no colon)"
  assert_contains "$out" "Version 2.0" "Version renders one per line (no colon)"
  assert_contains "$out" "ProtocolBinding urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" "ProtocolBinding renders one per line (no colon)"
  assert_not_contains "$out" "(ID=_req1" "attributes no longer rendered inline"
}

test_fetch_follows_redirect() {
  # A URL passed positionally (or via stdin) with no inline SAML payload is
  # fetched over HTTP, redirects followed, and decoded from the final URL.
  local dir server port url out status
  dir="$(mktemp -d)"
  python3 - "$dir" <<'PY' &
import base64, http.server, threading, time, zlib, urllib.parse, sys
d = sys.argv[1]
xml = ('<saml2p:AuthnRequest xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" '
       'xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="_req1" Version="2.0" '
       'ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" '
       'InResponseTo="_c1">'
       '<saml2:Issuer>urn:test-sp</saml2:Issuer>'
       '</saml2p:AuthnRequest>')
b64 = base64.b64encode(zlib.compress(xml.encode())).decode()
final = "/final?SAMLRequest=" + urllib.parse.quote(b64) + "&RelayState=abc-123"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/final"):
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
        else:
            self.send_response(302); self.send_header("Location", final); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
open(d + "/port", "w").write(str(port))
time.sleep(3600)
PY
  server=$!
  for _ in $(seq 1 50); do
    if [ -s "$dir/port" ]; then break; fi
    sleep 0.1
  done
  port="$(cat "$dir/port")"
  url="http://127.0.0.1:$port/redirect"
  capture_command out status "$BIN" "$url"
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  rm -rf "$dir"

  assert_status 0 "$status" "URL positional exits 0"
  assert_contains "$out" "Decoded SAMLRequest" "decodes fetched payload"
  assert_contains "$out" "urn:test-sp" "shows Issuer"
  assert_contains "$out" "_req1" "shows ID"
  assert_contains "$out" "/final" "followed redirect to final URL"
}

test_garbage() {
  printf 'garbage!!!not-base64' >"$FIXTURES/garbage.txt"
  capture_command out status "$BIN" <"$FIXTURES/garbage.txt"
  assert_status 1 "$status" "garbage exits 1"
  assert_contains "$out" "error" "garbage reports error"
}

test_empty_input() {
  printf '' >"$FIXTURES/empty.txt"
  capture_command out status "$BIN" <"$FIXTURES/empty.txt"
  assert_status 2 "$status" "empty input exits 2 (usage)"
  assert_contains "$out" "saml-decode" "empty input shows usage"
}

test_encrypted_no_key() {
  capture_command out status "$BIN" "$ENC_URL"
  assert_status 0 "$status" "encrypted (no key) exits 0"
  assert_contains "$out" "Encrypted:" "encrypted doc reports EncryptedData"
  assert_not_contains "$out" "urn:inner-assertion" "encrypted inner not leaked without key"
}

test_encrypted_with_key() {
  capture_command out status "$BIN" --key "$KEY" "$ENC_URL"
  assert_status 0 "$status" "encrypted (with key) exits 0"
  assert_contains "$out" "Decoded SAMLResponse (decrypted)" "encrypted marks decrypted"
  assert_contains "$out" "urn:inner-assertion" "decrypted inner is shown"
}

run_tests
