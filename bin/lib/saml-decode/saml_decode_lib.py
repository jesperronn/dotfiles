"""Shared helpers for bin/saml-decode and bin/saml-decode-keys.

Imported by both scripts via sys.path insertion (the filename has a hyphen,
so it cannot be imported directly). Callers do:

    import os, sys
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import saml_decode_lib as lib

Nothing here is required for the core decode path; it only loads when a
`keys` command runs or an encrypted doc needs auto-decryption. cryptography
is imported lazily inside the functions that need it.
"""

import base64
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

STORE_ROOT = os.path.expanduser("~/.config/saml-decode")

# ── store layout ──────────────────────────────────────────────────────────────
# ~/.config/saml-decode/<safe(idp-entity-id)>/{sp.key,sp.crt,idp.crt,meta.json}


def store_root():
    return STORE_ROOT


def _safe(name):
    """Turn an IdP entity-id (URN) into a safe directory name."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", name) or "default"


def store_dir(idp_entity_id):
    return os.path.join(store_root(), _safe(idp_entity_id))


def key_path(idp_entity_id):
    return os.path.join(store_dir(idp_entity_id), "sp.key")


def cert_path(idp_entity_id):
    return os.path.join(store_dir(idp_entity_id), "sp.crt")


def idp_crt_path(idp_entity_id):
    return os.path.join(store_dir(idp_entity_id), "idp.crt")


def meta_path(idp_entity_id):
    return os.path.join(store_dir(idp_entity_id), "meta.json")


def _write_file(path, data, mode):
    with open(path, "wb") as fh:
        fh.write(data)
    os.chmod(path, mode)


def save_store(idp_entity_id, meta, private_key_pem, cert_pem, idp_cert_pem=None):
    """Write sp.key (0600), sp.crt (0644), meta.json; optional idp.crt."""
    path = store_dir(idp_entity_id)
    os.makedirs(path, 0o700, exist_ok=True)
    _write_file(key_path(idp_entity_id), private_key_pem, 0o600)
    _write_file(cert_path(idp_entity_id), cert_pem, 0o644)
    if idp_cert_pem:
        _write_file(idp_crt_path(idp_entity_id), idp_cert_pem, 0o644)
    with open(meta_path(idp_entity_id), "w") as fh:
        json.dump(meta, fh, indent=2)


def load_store(idp_entity_id):
    p = meta_path(idp_entity_id)
    if os.path.exists(p):
        with open(p) as fh:
            return json.load(fh)
    return None


def list_stores():
    root = store_root()
    if not os.path.isdir(root):
        return []
    out = []
    for name in sorted(os.listdir(root)):
        if os.path.isfile(meta_path(name)):
            out.append(name)
    return out


def load_private_key(idp_entity_id):
    """Return the stored SP private key bytes (for decryption)."""
    with open(key_path(idp_entity_id), "rb") as fh:
        return fh.read()


def load_cert(idp_entity_id):
    with open(cert_path(idp_entity_id), "rb") as fh:
        return fh.read()


# ── cryptography (lazy) ───────────────────────────────────────────────────────


def generate_keypair(subject_cn, days=3650):
    """Return (private_key_pem_bytes, cert_pem_bytes), self-signed RSA-2048."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    priv_pem = priv.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )

    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(
            x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject_cn)]))
        .issuer_name(
            x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject_cn)]))
        .public_key(priv.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=days))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), True)
        .sign(priv, hashes.SHA256())
    )
    return priv_pem, cert.public_bytes(serialization.Encoding.PEM)


def _to_pem_cert(b64):
    b64 = re.sub(r"\s+", "", b64)
    lines = "\n".join(b64[i:i + 64] for i in range(0, len(b64), 64))
    return ("-----BEGIN CERTIFICATE-----\n" + lines +
            "\n-----END CERTIFICATE-----\n").encode("utf-8")


def _load_private(pem_bytes):
    from cryptography.hazmat.primitives import serialization
    return serialization.load_pem_private_key(pem_bytes, password=None)


# ── SAML metadata parsing ─────────────────────────────────────────────────────


def parse_metadata(xml_text):
    """Parse SAML metadata XML -> list of {use, certificate(PEM bytes)}.

    Matches any KeyDescriptor (any prefix) and any x509:Certificate block
    inside it, so it works for md:/ds:/x509 prefixes and rh-sso / Keycloak.
    """
    certs = []
    kd_pat = re.compile(
        r"<(?:[\w.:-]*:)?KeyDescriptor[^>]*>(.*?)</(?:[\w.:-]*:)?KeyDescriptor>",
        re.DOTALL | re.IGNORECASE)
    cert_pat = re.compile(
        r"(?:[\w.:-]*:)?x509:Certificate>([^<]*)</", re.IGNORECASE)
    for kd in kd_pat.finditer(xml_text):
        use_match = re.search(r'use="([^"]*)"', kd.group(0))
        use = use_match.group(1) if use_match else "signing"
        cm = cert_pat.search(kd.group(1))
        if cm:
            certs.append({"use": use, "certificate": _to_pem_cert(cm.group(1))})
    return certs


# ── Keycloak admin REST (lazy urllib, no deps) ────────────────────────────────


def _post_form(url, form):
    body = urllib.parse.urlencode(form).encode("utf-8")
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _get_json(url, headers):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def keycloak_token(base_url, realm, client_id, client_secret=None,
                   username=None, password=None):
    """Obtain an admin access token.

    password grant when username/password given (older Keycloak); otherwise
    client_credentials with a client secret. Returns the raw token string.
    """
    token_url = f"{base_url}/realms/{realm}/protocol/openid-connect/token"
    data = {"client_id": client_id}
    if username and password:
        data["grant_type"] = "password"
        data["username"] = username
        data["password"] = password
    else:
        data["grant_type"] = "client_credentials"
        if client_secret:
            data["client_secret"] = client_secret
    return _post_form(token_url, data)["access_token"]


def keycloak_list_clients(base_url, realm, client_id, token):
    """GET /admin/realms/{realm}/clients?clientId={client_id} -> [client...]."""
    url = (f"{base_url}/admin/realms/{realm}/clients"
           f"?clientId={urllib.parse.quote(client_id)}")
    return _get_json(url, {"Authorization": f"Bearer {token}"})


def keycloak_update_client(base_url, realm, client_uuid, attributes, token):
    """PUT /admin/realms/{realm}/clients/{uuid} with a dict of attributes."""
    url = f"{base_url}/admin/realms/{realm}/clients/{client_uuid}"
    body = json.dumps({"attributes": attributes}).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, method="PUT",
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status


def keycloak_update_sp_certificate(base_url, realm, client_id, token,
                                   cert_pem):
    """Convenience: set saml.server.signature.certificate to the SP cert PEM."""
    clients = keycloak_list_clients(base_url, realm, client_id, token)
    if not clients:
        raise RuntimeError(f"no client '{client_id}' found in realm {realm}")
    client = clients[0]
    uuid = client["id"]
    attrs = dict(client.get("attributes") or {})
    attrs["saml.server.signature.certificate"] = cert_pem.decode("utf-8")
    keycloak_update_client(base_url, realm, uuid, attrs, token)
    return uuid


# ── auto-decrypt support (used by bin/saml-decode) ────────────────────────────


def find_response_target(doc):
    """Best-effort visible target from an encrypted doc: Response Destination
    or any Recipient. Used to pick which store's sp.key to try."""
    for m in re.finditer(
            r"(?:[\w.:-]*:)?Response[^>]*?\sDestination=\"([^\"]*)\"",
            doc, re.IGNORECASE):
        return m.group(1)
    for m in re.finditer(r'(?:[\w.:-]*:)?Recipient="([^"]*)"', doc,
                         re.IGNORECASE):
        return m.group(1)
    return None


def try_stores_for_doc(doc):
    """Yield each stored idp entity-id (caller tries sp.key on each)."""
    return list_stores()


def to_property_list(xml_text: str, color: bool = False) -> str:
    """Render XML as a flat, human-readable property list — one property per line.

    Namespace prefixes are stripped (local names only); namespace-declaration
    attributes (xmlns...) and XML comments are omitted. Element attributes are
    shown inline as (k=v, k2=v2) with local (namespace-stripped) keys. Text-only
    elements render as `localname: text`. Children are indented two spaces per
    depth level (AuthnRequest's children one extra level). Returns a string with
    NO trailing newline (caller joins).

    When `color=True`, emit ANSI SGR codes: element/attribute names (keys) in
    bold cyan, values in white; important text values (Issuer, Destination) are
    bold and token values (ID, Version, ProtocolBinding, Signature, RelayState)
    are dimmed. Keys are aligned so values line up.

    Never raises on malformed XML: falls back to a flat regex extraction of
    `<localname ...>text</localname>` pairs so encrypted/odd docs still render.
    """

    items = []

    def collect(elem, depth):
        name = _local(elem.tag)
        attrs = [(k, v) for k, v in elem.items() if "xmlns" not in k]
        items.append((depth, name, attrs, (elem.text or "").strip()))
        for child in elem:
            # indent AuthnRequest's children one extra level
            collect(child, depth + 1 + (1 if name == "AuthnRequest" else 0))

    try:
        import xml.etree.ElementTree as ET
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        flat = []
        for m in re.finditer(
                r"<([A-Za-z_][\w.:-]*)([^>]*?)>([^<]*)</", xml_text):
            t = m.group(3).strip()
            if t:
                flat.append((0, _local(m.group(1)), [], t))
        return "\n".join(_plain_line(d, n, a, v) for d, n, a, v in flat)

    collect(root, 0)
    if not color:
        return "\n".join(_plain_line(d, n, a, v) for d, n, a, v in items)

    # align key width among value lines
    key_width = max(
        (len(_plain_header(n, a)) for d, n, a, v in items if v), default=0)
    return "\n".join(
        _styled_line(d, n, a, v, key_width) for d, n, a, v in items)


def _local(tag):
    """Local name: substring after `}` (URI) or after the last `:`."""
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    idx = tag.rfind(":")
    return tag[idx + 1:] if idx != -1 else tag


def _plain_header(name, attrs):
    """Unstyled header: `name` or `name (k=v, k2=v2)` with local keys."""
    return ((name + " (" + ", ".join(
        "%s=%s" % (_local(k), v) for k, v in attrs) + ")") if attrs else name)


def _plain_line(depth, name, attrs, value):
    """Render one line, unstyled."""
    return ("  " * depth + _plain_header(name, attrs)) + (
        ": " + value if value else "")


# ANSI styling constants — used only when color=True.
_P = "\x1b[0m"
_B = "\x1b[1m"
_DIM = "\x1b[2m"
_CYAN = "\x1b[36m"
_WHITE = "\x1b[37m"

# Text-value names: important content (bold) vs token values (dimmed).
_BOLD_VALUES = {"issuer", "destination"}
_DIM_VALUES = {"id", "version", "protocolbinding", "signature",
               "relaystate", "mustunderstand", "inresponseto",
               "idpssourl", "assertionidref", "issueinstant"}


def _key(s):
    """Wrap a key (element or attribute name) in bold cyan."""
    return _B + _CYAN + s + _P


def _val(s, name):
    """Wrap a text value: bold if important, dimmed if token, else plain."""
    ln = name.lower()
    if ln in _BOLD_VALUES:
        return _B + s + _P
    if ln in _DIM_VALUES:
        return _DIM + s + _P
    return s


def _styled_header(name, attrs):
    """Styled header: bold-cyan name + inline (bold-cyan key = styled value)."""
    head = _key(name)
    if attrs:
        kv = ", ".join("%s=%s" % (_key(_local(k)), _val(v, _local(k)))
                       for k, v in attrs)
        return head + " (" + kv + ")"
    return head


def _styled_line(depth, name, attrs, value, key_width):
    """Render one line with ANSI styling; keys aligned to `key_width`."""
    pad = max(0, key_width - len(_plain_header(name, attrs)))
    return ("  " * depth + _styled_header(name, attrs) + " " * pad + (
        ": " + _val(value, name) if value else ""))
