# Ecosystems

Inspect project files and CI before choosing languages. Include nested modules;
ignore vendor directories and build output. Bootstrap takes explicit selections.

| Language | Evidence | Prefer |
| --- | --- | --- |
| bash (`sh` alias) | shell tests or maintained shell tools | existing harness, shellcheck, shfmt |
| ruby | Gemfile | binstubs; Rails or RSpec as configured |
| js | package.json | lockfile's package manager and project scripts |
| go | go.mod | go test, gofmt, go vet |
| java | pom.xml or build.gradle[.kts] | mvnw/gradlew, configured test and lint tasks |

The generated scripts are starting points. Confirm package scripts, test naming,
workspace paths, and installed plugins. Runtime tool selection stays within the
chosen languages. Keep toolchain upgrades separate from dependency updates.
