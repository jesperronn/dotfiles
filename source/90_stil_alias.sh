# shellcheck shell=bash

export STIL_HOME="${HOME}/src/stil"

# from https://www.keycloak.org/docs/latest/server_admin/index.html#installing-the-admin-cli
export KEYCLOAK_HOME="${HOME}/src/stil/binaries/rh-sso-7.6"
export PATH="${PATH}:${KEYCLOAK_HOME}/bin"
export PATH="${PATH}:${HOME}/src/stil/support-tools/bin"

stil_cert() {
  eval "pbpaste | normalize_cert | openssl x509 -text -noout"
}
export -f stil_cert

