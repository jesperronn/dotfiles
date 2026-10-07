# apicall

A Node.js 22+ wrapper around curl. API hosts, prefixes, headers and credential references live in TOML; curl options go after `--`.

## Start

```bash
bin/apicall setup
# Edit ~/.config/apicall.toml (fictional examples must be replaced).
bin/apicall validate
bin/apicall list
bin/apicall environments uniapi
bin/apicall describe uniapi prod
bin/apicall preview uniapi prod job/check-certificates/info
```

Setup copies [the commented template](../bin/apicall.toml.template), creates directories and a 0600 file, and never overwrites an existing config. `APICALL_CONFIG=/path/to/config.toml` selects another file for all commands. Config is not created automatically during requests.

## Calls

```bash
apicall call uniapi prod job/check-certificates/info
apicall call uniapi prod job/check-certificates/pause -- -X POST
apicall call awx staging projects/ -- -k --connect-timeout 5 --max-time 30
apicall call custom dev widgets -- --json @widget.json
apicall call custom dev 'widgets?limit=10&active=true' | jq .
```

A path is relative to the configured API prefix. Leading boundary slashes are accepted; endpoint trailing slashes and query strings are preserved. An empty endpoint selects the API base with a trailing slash. Absolute URLs, fragments and literal dot segments are rejected.

Response output stays raw. Curl errors go to stderr; curl exit status is preserved, including status 22 with response body for HTTP errors. There are no automatic redirects or retries. Default TLS verification is enabled. Caller-supplied curl options can change these defaults.

## Configuration

See the template for every field and examples of `none`, `basic`, `bearer`, and custom `header` authentication.

`{env}` is lowercase and `{ENV}` uppercase. They expand in origin, API prefix, environment-variable names and 1Password references. Unknown placeholders fail validation. There is no shell evaluation.

Environment settings override service API prefix, individual headers case-insensitively, and auth fields. Changing auth type replaces the auth definition. Credential source fields merge. All environments are validated when loading config.

Credential policy lives only in config:

- `env`: strict environment variables; never accesses 1Password.
- `op`: strict 1Password references, ignoring environment credentials.
- `env-or-op`: use complete environment credentials; otherwise retrieve from 1Password. Basic username/password switch providers together.

Use `env` for unattended calls. Example credential references:

```toml
[services.uniapi.auth]
type = "basic"
credential_policy = "env"
[services.uniapi.auth.username]
env = "API_SERVER_{ENV}_USERNAME"
[services.uniapi.auth.password]
env = "API_SERVER_{ENV}_PASSWORD"
```

No resolved secrets are cached or written to your configuration. Basic usernames cannot contain a colon. Authentication failures do not trigger fallback. Preview and discovery never call curl or op. Preview omits passthrough values and shows explicit methods as a placeholder.

The parser supports a documented TOML subset: tables, basic double-quoted strings (including escapes), quoted keys, integer version, and comments. Arrays, multiline/literal strings, inline tables and other value types are unsupported. Schema version must be 1. Unknown fields and duplicate keys/tables fail clearly.

## Curl options

Argument boundaries are preserved, including spaces in a body/header. Short options taking a value accept attached values (`-XPOST`); use separate short flags (`-k -s`, not `-ks`). Long value options accept `--name=value` or `--name value`.

Supported value options:

```text
--connect-timeout --max-time --request --header --data --data-raw
--data-binary --data-urlencode --json --output --output-dir --dump-header
--user --proxy-user --proxy --noproxy --cacert --capath --cert --key
--cert-type --key-type --pass --resolve --connect-to --interface
--url-query --upload-file --form --form-string --cookie --cookie-jar
--referer --user-agent --range --limit-rate --retry --retry-delay
--retry-max-time --write-out --max-redirs --request-target --unix-socket
--proto --proto-redir --tls-max --trace --trace-ascii
```

Supported flags:

```text
--insecure --silent --show-error --verbose --location --location-trusted
--head --include --compressed --get --fail --fail-with-body --no-fail
--no-fail-with-body --http1.0 --http1.1 --http2 --http2-prior-knowledge
--ipv4 --ipv6 --no-progress-meter --progress-bar --globoff --retry-all-errors
--retry-connrefused --tcp-nodelay --no-keepalive --tlsv1.2 --tlsv1.3
--basic --digest --anyauth --netrc --netrc-optional
```

Standard short equivalents are supported: `-X -H -d -o -D -u -U -x -T -F -b -c -e -A -r -w`, and `-k -s -S -v -L -I -i -G -f -g -4 -6 -#`.

Extra URLs, `--url`, `--next`, curl config-file loading, and unknown options are rejected. Curl's implicit `.curlrc` and URL globbing are disabled. Configured defaults precede user options; repeated-option behavior follows curl, including header accumulation.

Tracing and caller-supplied credential options can expose credentials through curl's own output. Configured auth uses a private temporary config instead of process arguments; it is removed after execution and catchable termination. Abrupt termination can leave that private temporary file.

## Verification

```bash
node --check bin/apicall
bin/lint bin/apicall.test.sh
bin/runtests bin/apicall.test.sh
```

Tests use a local HTTP server with dummy environment credentials, plus PATH mocks for curl/op. They never call real 1Password. A restricted sandbox may require permission for the loopback listener.

Implementation references: [curl options](https://curl.se/docs/manpage.html), [1Password op read](https://www.1password.dev/cli/reference/commands/read).
