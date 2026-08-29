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
