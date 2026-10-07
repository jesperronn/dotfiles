# apicall v1 specification

Status: implementation authorized on 2026-10-02 and completed in the current checkout. See ../../apicall.md for usage and ../plans/2026-10-02-apicall.md for verification evidence.

## Metadata

- start_time: 2026-10-01T14:38:42+02:00
- input_question: Consolidate the agreed apicall design into a spec document for review.
- creation_time_seconds: 140
- tool_name: codex

## Purpose and scope

Provide a small configuration-driven curl wrapper that remembers API prefixes, environment hosts, headers, authentication types, and credential references. The caller selects a service, environment, and relative endpoint. Curl handles HTTP and caller-supplied request options.

Implement in Node.js, following bin/copilot-leaderboard in /Users/jesper/src/dotfiles. Copy and adapt its executable structure, home-folder path handling, template creation, config loading and validation, help/error patterns, and spawnSync usage. Do not refactor that existing tool or introduce a shared library in v1.

## Deliverables

- bin/apicall: one Node.js executable.
- bin/apicall.toml.template: commented configuration template.
- bin/apicall.test.sh: neighboring test file following the implementation repository's test runner conventions.
- User documentation with setup and common calls.

The reference tool resides in /Users/jesper/src/dotfiles, whereas this document is saved in /Users/jesper/.dotfiles. Implementation uses the current /Users/jesper/.dotfiles checkout; the newer checkout remains a read-only reference.

## Commands

```text
apicall setup
apicall list
apicall environments <service>
apicall describe <service> <environment>
apicall validate
apicall preview <service> <environment> <path> [-- <curl arguments>]
apicall call <service> <environment> <path> [-- <curl arguments>]
```

Tool actions are subcommands. Help is available through --help globally and for each subcommand. Request method defaults to GET; HTTP options belong after --.

```bash
apicall setup
apicall validate
apicall call uniapi prod job/check-certificates/info
apicall call uniapi prod job/check-certificates/pause -- -X POST
apicall call awx staging projects/ -- -k --connect-timeout 5 --max-time 30
apicall call custom dev widgets -- --json @widget.json
apicall call awx staging projects/ | jq .
```

No --credentials, --1password, or JSON-formatting wrapper flags.

## Configuration location and setup

Default config: ~/.config/apicall.toml. APICALL_CONFIG overrides that path for every subcommand, including setup. No automatic project-local config lookup.

Setup copies bin/apicall.toml.template from beside the executable to the selected config path, preserving comments. It creates missing directories, writes with owner-only permissions (0600), and refuses to overwrite an existing file. Creation must be exclusive to avoid an overwrite race. It prints the path, editing instructions, and the validate command. It makes no API calls or secret lookups. A missing shipped template produces a clear error without creating an incomplete config.

The template is the single source for setup contents. It explains every supported option, inheritance, auth types, credential policies, placeholders, and environment overrides. Include editable examples for basic, bearer, custom-header, and unauthenticated access. Use fictional hosts and credential references, never actual secret values.

## TOML schema

```toml
version = 1

[services.uniapi]
api_path = "/api"

[services.uniapi.headers]
Accept = "application/json"

[services.uniapi.auth]
type = "basic"
credential_policy = "env-or-op"

[services.uniapi.auth.username]
env = "API_SERVER_{ENV}_USERNAME"
op = "op://Work/uniapi-{env}/username"

[services.uniapi.auth.password]
env = "API_SERVER_{ENV}_PASSWORD"
op = "op://Work/uniapi-{env}/password"

[services.uniapi.environments.dev]
origin = "https://dev.uniapi.stil.dk"

[services.uniapi.environments.staging]
origin = "https://staging.uniapi.stil.dk"

[services.uniapi.environments.prod]
origin = "https://prod.uniapi.stil.dk"

[services.uniapi.environments.prod.auth]
credential_policy = "op"
```

Version 1 is required. Service and environment identifiers use letters, digits, underscores, and hyphens. At least one environment per service is required.

Support the documented TOML subset: tables, quoted string keys where needed for header names, basic strings with necessary escape handling, integer version, blank lines, and comments including trailing comments outside strings. Reject duplicate definitions, unsupported syntax, and unknown schema fields with line/context errors. Adapt the reference parser to this schema; do not claim complete TOML compatibility. Arrays, inline tables, multiline strings, dates, and other TOML types are outside v1.

Service defaults include api_path (default empty), headers (default empty), and auth (default type none). Each environment must have origin. Environments may override api_path, individual headers case-insensitively, and individual auth fields and credential source fields. If auth type changes, replace the auth definition and require all fields for the new type; do not inherit incompatible fields. No deletion syntax in v1.

### Placeholders

- {env}: selected environment name lowercased.
- {ENV}: selected environment name uppercased.

Expand in origin, api_path, environment-variable names, and 1Password references. For prod, API_SERVER_{ENV}_USERNAME becomes API_SERVER_PROD_USERNAME and op://Work/uniapi-{env}/username becomes op://Work/uniapi-prod/username. Only those two placeholders are supported in these fields; reject unknown or malformed placeholders. No shell expansion, command substitution, or eval. Other fields are literal.

## Authentication and credential sources

Supported auth types:

| Type | Required fields | Behavior |
| --- | --- | --- |
| none | None | No configured authentication |
| basic | username, password | Curl HTTP Basic authentication |
| bearer | token | Authorization header with Bearer prefix |
| header | name, token; optional prefix | Named header; prefix defaults to empty |

For header auth, prefix is literal, including any desired separating space. Header values and resolved credentials must not contain CR/LF or NUL. Reject conflicting configured headers and auth-generated headers.

Credential source objects contain env (environment-variable name), op (1Password secret reference), or both. Literal secrets are unsupported. Retrieve op references with op read using separate process arguments.

Credential policy is configured only in auth, optionally overridden per environment:

| Policy | Resolution |
| --- | --- |
| env (default) | Require nonempty environment credentials; never call op |
| op | Require op references; ignore environment credentials |
| env-or-op | Prefer complete environment credentials; otherwise require op references |

Under env-or-op, basic username/password resolve as a pair. If either env value is absent or empty, retrieve both from op; never mix providers. Do not trim credential values. Missing source declarations fail validation. Runtime missing values or op failures fail before curl. Authentication rejection never triggers fallback or automatic retries. Secrets are resolved per invocation and not persisted or cached.

## URL construction

Construct origin + api_path + requested path. Normalize boundary slashes only; preserve endpoint trailing slashes, percent escapes, and query strings. Do not decode and re-encode the endpoint. A leading slash on the endpoint is accepted as a boundary slash, not an origin-relative override. Empty path addresses the API base with a trailing slash.

Origin must be an HTTP(S) origin without userinfo, path other than /, query, or fragment. api_path is a path prefix without query or fragment. Reject absolute/scheme-relative endpoint URLs, fragments, and literal . or .. path segments. Do not deduplicate an API prefix supplied twice. Quote shell-sensitive query strings.

## Curl passthrough

Preserve every argument after -- as a separate argument; never build an executable shell string. Configured defaults precede passthrough arguments. Curl's own option-specific precedence applies; do not promise all repeated options override (headers, for example, can accumulate).

Support -k, timeout options, methods, headers, bodies, output files, and ordinary curl options. The resolved target is supplied as one explicit curl URL. Disable URL globbing so bracketed values remain literal. Disable implicit .curlrc loading by placing curl's disable-config option first.

Restrict the interface to one configured request: reject additional URL operands, --url, --next, and explicit curl config-file loading. Recognize aliases, attached short-option values, and --option=value forms. Account for value-taking options so a filename or body value is not mistaken for a URL. Use an explicit documented option table; unknown/ambiguous options fail with a helpful message. Thus passthrough is broad but not an unrestricted promise of compatibility with every curl version or syntax. Extend the table as needed without changing the command interface.

Explicit curl options can change authentication, follow redirects, route traffic, or expose credentials through tracing. The wrapper does not claim that arbitrary caller-selected curl options are safe. It must never add secret values to its own diagnostics.

## Preview, discovery, and errors

- list: sorted configured service names.
- environments: sorted environment names for the service.
- describe: effective config including credential references and policy, never resolved credentials.
- validate: validate all effective environments without credential lookups or network calls.
- preview: validate and resolve the same request as call, but never invoke curl or op. Show method/URL, configured headers, credential references/placeholders, and passthrough option names with values omitted to avoid exposing caller-supplied secrets. No copy-paste executable command containing secrets.

Missing config errors show its path and recommend apicall setup. Unknown service/environment errors list valid choices. Help remains available without a valid config. Usage/config/credential failures return 1; help and successful discovery/setup/preview return 0.

Call defaults to curl silent mode with error reporting and HTTP fail-with-body behavior. Preserve raw response output and curl exit status. Passthrough can explicitly change curl behavior. No automatic retries, redirects, or insecure TLS. Curl must support the required defaults; fail helpfully if unsupported. Curl is required only for call; op only when the effective credential policy uses it.

Keep resolved secrets out of process arguments. Use a private, correctly escaped temporary curl config for authentication, with exclusive creation and restrictive permissions; remove it on success/failure and catchable termination. Do not log its contents. Document that abrupt process termination can leave a temporary file, and avoid persistent secret storage.

## Implementation sequence and verification

1. Read the intended repository's instructions and inspect current Node/test/lint conventions. Preserve unrelated work.
2. Add the executable skeleton, documented TOML template, loader, schema validation, inheritance, placeholders, setup, and discovery commands.
3. Implement credential resolution and auth construction with mocked op tests.
4. Implement URL resolution, curl passthrough parsing, and preview with argument-boundary tests.
5. Implement curl execution and temporary-secret lifecycle; test stdout/stderr and exit behavior with mocked curl.
6. Run focused tests and repository lint, then inspect the diff against this spec. No real production API calls are required.

Acceptance coverage: commented template copying; overwrite refusal; permissions; alternate config path; TOML quoted keys/comments/escapes and rejection cases; environment overrides; both placeholder cases; all auth types and policies; paired basic fallback; missing/empty credentials; no fallback after HTTP rejection; URL joining/query/trailing slash preservation; curl argument boundaries and prohibited-target forms; unknown-option errors; preview making no curl/op calls; no wrapper secret disclosure; temporary-file cleanup; response bodies and curl exit codes.

## Deferred scope

Swagger discovery, endpoint aliases, pagination, login/session flows, secret caching, shared-library extraction, full TOML parsing, arbitrary curl syntax compatibility, and service-specific workflows such as Jenkins CSRF negotiation.

## Review boundary

The user approved autonomous implementation on 2026-10-02. Verification uses dummy environment credentials or mocked op, never real 1Password access.
