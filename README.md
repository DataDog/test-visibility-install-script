# <img height="25" src="CIVislogo.png" /> Datadog Test Optimization installation script

A script that installs Datadog tracing libraries and prints environment variables necessary for configuring [Datadog Test Optimization](https://docs.datadoghq.com/tests/).
The variables are printed in the following format: variableName=variableValue

Supported languages are .NET, Java, Javascript, Python, Ruby and Go.

## About Datadog Test Optimization

[Test Optimization](https://docs.datadoghq.com/tests/) provides a test-first view into your CI health by displaying important metrics and results from your tests.
It can help you investigate and mitigate performance problems and test failures that are most relevant to your work, focusing on the code you are responsible for, rather than the pipelines which run your tests.

## Usage

Run the script with the necessary parameters:

```shell
DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=... DD_API_KEY=... ./install_test_visibility.sh
```

The script parameters are

- `DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES`: (required) List of languages to be instrumented. Can be either `all` or any of `java`, `js`, `python`, `dotnet`, `ruby`, `go` (multiple languages can be specified as a space-separated list).
- `DD_API_KEY`: (required for .NET tracer installation) Datadog API key. Can be found at <https://app.datadoghq.com/organization-settings/api-keys>
- `DD_TRACER_FOLDER`: (optional) The folder where the tracing libraries will be installed, defaults to `./.datadog`. For JavaScript on Linux and macOS it must not contain spaces, because the tracer's paths are appended to `NODE_OPTIONS` without quotes
- `DD_SITE`: (optional) Datadog site, defaults to US1. See <https://docs.datadoghq.com/getting_started/site> for more information about sites.
- `DD_SET_TRACER_VERSION_DOTNET`: (optional) Version of the .NET tracer to install. If not provided, the latest version is installed.
- `DD_SET_TRACER_VERSION_JAVA`: (optional) Version of the Java tracer to install (without the `v` prefix, e.g. `1.37.1`). If not provided, the latest version is installed.
- `DD_SET_TRACER_REPOSITORY_URL_JAVA`: (optional) Base URL of a Maven repository (or proxy/mirror) used to download the Java tracer JAR and its `.sha256`. The path under the base must follow the standard Maven layout for `com.datadoghq:dd-java-agent` (i.e. `<base>/<version>/dd-java-agent-<version>.jar`, plus `<base>/maven-metadata.xml` when `DD_SET_TRACER_VERSION_JAVA` is not pinned). Trailing slashes are tolerated. Defaults to `https://repo1.maven.org/maven2/com/datadoghq/dd-java-agent`.
- `DD_SET_AUTH_HEADER_JAVA`: (optional) HTTP header used to authenticate against `DD_SET_TRACER_REPOSITORY_URL_JAVA`, provided as a complete `Name: Value` string (e.g. `Authorization: Bearer <token>`). Passed verbatim to `curl -H` / `wget --header` on every Java tracer download. Requires `DD_SET_TRACER_REPOSITORY_URL_JAVA` to be set to a custom repository URL. Redirects are followed by default; be aware that the header will be re-sent on each redirect hop with the following caveats: `curl` strips `Authorization` and `Cookie` headers on cross-origin redirects (different host, port, or scheme), but `wget` does not strip any header. Custom header names (e.g. `X-API-Key`, `X-JFrog-Art-Api`) are never stripped by either tool — prefer the `Authorization: …` form when possible. Set `DD_SET_AUTH_HEADER_JAVA_DISABLE_REDIRECTS` to opt out of redirect following entirely.
- `DD_SET_AUTH_HEADER_JAVA_DISABLE_REDIRECTS`: (optional) When set to any non-empty value, disables HTTP redirect following for Java tracer downloads that send `DD_SET_AUTH_HEADER_JAVA`. Use this if your repository never redirects and you want to guarantee the auth header is only ever sent to the configured `DD_SET_TRACER_REPOSITORY_URL_JAVA` host. It needs curl or a wget with `--max-redirect`, such as GNU wget; with BusyBox's wget the script fails instead.
- `DD_SET_TRACER_VERSION_JS`: (optional) Version of the JS tracer to install. If not provided, the latest version is installed.
- `DD_SET_TRACER_VERSION_PYTHON`: (optional) Version of the Python tracer to install. If not provided, the latest version is installed.
- `DD_SET_TRACER_VERSION_RUBY`: (optional) Version of the Ruby datadog-ci gem to install. If not provided, the latest version is installed.
- `DD_SET_TRACER_VERSION_GO`: (optional) Version of [ddtest](https://github.com/DataDog/ddtest) to install for Go, such as `v1.16.0`; `v1.14.0` is the oldest supported. If not provided, the latest release is installed. This variable used to select an Orchestrion version: a value that names no ddtest release from `v1.14.0` on, such as an earlier Orchestrion version or commit, installs the latest ddtest with a warning. Update pinned values, because a number such as `v1.15.0` now names a ddtest release. See [Tracing Go tests](#tracing-go-tests).
- `DD_SET_TRACER_REPOSITORY_URL_GO`: (optional) Base URL of a mirror of [ddtest's GitHub releases](https://github.com/DataDog/ddtest/releases), for runners that cannot reach `github.com`. It must keep their layout: `<base>/latest/download/<file>` for the latest release and `<base>/download/<tag>/<file>` for a pinned one, with each release's `SHA256SUMS` and executables. Trailing slashes are tolerated. Credentials in the URL, such as `https://user:token@host/...`, are left out of the script's messages. Defaults to `https://github.com/DataDog/ddtest/releases`.
- `DD_SET_AUTH_HEADER_GO`: (optional) HTTP header used to authenticate against `DD_SET_TRACER_REPOSITORY_URL_GO`, provided as a complete `Name: Value` string (e.g. `Authorization: Bearer <token>`), sent with every ddtest download. Requires `DD_SET_TRACER_REPOSITORY_URL_GO` to be set to a mirror, so the header never goes to `github.com`. Redirects are followed by default, with the same caveats as `DD_SET_AUTH_HEADER_JAVA`.
- `DD_SET_AUTH_HEADER_GO_DISABLE_REDIRECTS`: (optional) When set to any non-empty value, disables HTTP redirect following for ddtest downloads that send `DD_SET_AUTH_HEADER_GO`. It needs curl or a wget with `--max-redirect`, such as GNU wget: BusyBox's wget, on Alpine images, always follows redirects, so the script fails instead.
- `DD_INSTRUMENTATION_BUILD_SYSTEM_JAVA`: (optional) A hint for Java instrumentation to instrument a specific build system. Allowed values are `maven`, `gradle`, `sbt`, `ant`, and `all`. If not specified, every Maven, Gradle, SBT, and Ant build will be instrumented. `all` is a special value that allows instrumenting _every JVM process_.

The script will install the libraries and print the list of environment variables that should be set in order to enable Test Optimization. Example output:

```shell
DD_CIVISIBILITY_ENABLED=true
DD_CIVISIBILITY_AGENTLESS_ENABLED=true
DD_ENV=ci
JAVA_TOOL_OPTIONS=-javaagent:./.datadog/dd-java-agent.jar
```

If you want to set the variables printed by the script, use the following expression:

```shell
while IFS='=' read -r name value; do
  if [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    export "$name=$value"
  fi
done < <(DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=[...] DD_API_KEY=[...] ./install_test_visibility.sh)
```

## Limitations

### Tracing Go tests

Go tests report through [`ddtest instrument`](https://github.com/DataDog/ddtest/blob/main/ddto/README.md). The script downloads ddtest into `DD_TRACER_FOLDER` and checks it against the release's `SHA256SUMS`. It then puts ddtest's `go` command first on `PATH`: that `go` runs `go test` through `ddtest instrument`, also when `make`, a script or [gotestsum](https://github.com/gotestyourself/gotestsum) starts it (as a binary, with `go run` or with `go tool`), and runs every other `go` command unchanged. The script no longer edits `go.mod` or sets `GOFLAGS`.

- The script prints `PATH` with that directory first. In GitHub Actions it also adds the directory to `GITHUB_PATH`, because the job's next steps get the directories listed there, such as `actions/setup-go`'s, before a `PATH` set through `GITHUB_ENV`. On Windows in GitHub Actions it prints no `PATH`, since Git Bash's `PATH` has POSIX paths that later steps cannot use: there, only the job's next steps get the directory, not the step that runs the script.
- The runner needs Go 1.25 or newer on `PATH`; with an older toolchain the script prints a warning, skips Go and lets the job continue. The project's `go.mod` can still declare an older Go version.
- Linux, macOS and Windows, from Git Bash, on `amd64` and `arm64` are supported; elsewhere the script skips Go with a warning.
- Tests must run on the same machine or container and as the same user as the script, since ddtest's `go` command lives in that user's cache directory: a Docker container action that runs the tests does not find it. No later step may put another `go` before ddtest's on `PATH`, such as installing Go again after running the script; otherwise `go test` runs without Test Optimization.
- With Test Impact Analysis enabled, build the tests with coverage in count or atomic mode, such as `go test -cover -covermode=atomic ./...`, so each test reports the code it ran.

### Tracing vitest tests

ℹ️ This section is only relevant if you're running tests with [vitest](https://github.com/vitest-dev/vitest).

To use this script with vitest you need to modify the NODE_OPTIONS environment variable adding the `--import` flag with the value of the `DD_TRACE_ESM_IMPORT` environment variable.

```shell
export NODE_OPTIONS="$NODE_OPTIONS --import=$DD_TRACE_ESM_IMPORT"
```

**Important**: `vitest` and `dd-trace` require Node.js>=18.19 or Node.js>=20.6 to work together.

### Tracing cypress tests

To instrument your [Cypress](https://www.cypress.io/) tests with Datadog Test Optimization, please follow the manual steps in the [docs](https://docs.datadoghq.com/tests/setup/javascript/?tab=cypress).
