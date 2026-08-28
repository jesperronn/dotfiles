# saml-decode plan

## Phase 1 — stdin SAML decoder (current)

`bin/saml-decode`: reads a SAML URL / query string / bare base64 blob from
stdin or argv; URL-decode → base64 → zlib/deflate/gzip auto-detect →
pretty-printed XML. Prints header (URL, how-decoded, RelayState, SigAlg,
Signature). `--raw` = unindented. Encrypted docs are detected and reported
(decryption requires `--key <sp-private-key.pem>`, optional
`cryptography` dependency, lazy import).

## Follow-up — key management for encrypted responses

Problem: the IdP encrypts assertions for the SP cert registered in the IdP's
client config. Decrypting needs the matching SP private key. Goal: one easy
flow to get the right keys in place so `saml-decode` decrypts without
fumbling, and the IdP knows which SP cert to encrypt to.

### Key store

`~/.config/saml-decode/<idp-entity-id>/` (also addressable by `--name`):

```
sp.key     PEM private key            (0600)
sp.crt     X.509 SP cert — the copy registered in the IdP   (0644)
idp.crt    IdP signing cert, fetched from metadata
meta.json  { idpEntityId, idpMetadataUrl, spEntityId, keycloak: { realm, clientId, user? }, createdAt }
```

Keyed by IdP entity ID so multiple IdPs coexist; entity ID can be guessed
from a decoded doc's `<saml:Issuer>` (`keys init --from <decoded-or-stdin>`).

### Commands (subcommands of saml-decode)

- `keys init --idp <urn> --sp-urn <urn> [--metadata-url u] [--days 3650]`
  Generate RSA-2048 keypair + self-signed cert (via `cryptography`), or
  `keys init --key k.pem --cert c.crt` to import an existing SP key/cert.
  Writes store, correct perms, prints what was created + next step
  (register).
- `keys fetch-idp [--idp <urn>]`
  GET the metadata URL (from meta.json or `--metadata-url`), parse
  `md:KeyDescriptor use="signing"/"encryption"` → base64 `x509:Certificate`
  blocks, save as `idp.crt` (print PEMs + fingerprints). Non-Keycloak IdPs
  work the same — SAML metadata is the standard path.
- `keys register [--idp <urn>]`
  Push `sp.crt` into the IdP.
  - Keycloak admin REST: obtain token (password grant or
    client_credentials; `--user/--password` or `--token`), `GET
    /admin/realms/{realm}/clients?clientId={clientId}` → uuid, `PUT` client
    attributes setting `saml.server.signature.certificate` = SP cert PEM.
  - Fallback: print the equivalent `sso-admin.sh update-client -r <realm>
    -s <client> --attribute saml.server.signature.certificate="$(cat sp.crt)"`
    (rh-sso 7.6, already in `~/src/stil`) or `kcadm.sh` command for the user.
  - **CONFIRM against installed version before wiring**: attribute name and
    whether a separate encrypt-assertions toggle is required. 7.6/rh-sso:
    `saml.server.signature.certificate` is the SP cert attribute. Newer
    Keycloak (17+/24+): verify attribute names + the "Encrypt assertions"
    client config attribute.
- `keys list`, `keys show <idp>` — inspect store.

### Auto-decrypt in the decode path

Encrypted doc, no `--key`: resolve store by `samlp:Response@Destination` /
`Recipient` (SP entity ID is visible even when the assertion is encrypted).
Match → decrypt with `sp.key`, header notes which key file was used.
No match → current `Encrypted: pass --key ...` note. `--key` stays as
explicit override.

### Phase 3 candidate (only if asked)

Signature verification: verify the XML-DSig against `idp.crt` — needs
canonicalization (enveloped-signature exclusive C14N); `cryptography` +
manual C14N or shell out to `xmlsec1`. Not trivial; deferred.

### Open questions

1. Target Keycloak version(s): 7.6 (rh-sso in stil) only, or also 24/25+?
   Drives admin API shape and attribute names.
2. Self-signed SP cert acceptable for `docker.localhost`, or is there an
   internal CA that should sign it (init then `--cert` import path)?
3. Credentials path for `keys register`: password grant (deprecated in newer
   KC, removed in 26+?) vs a dedicated client_credentials admin client?
