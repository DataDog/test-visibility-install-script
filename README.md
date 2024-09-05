# <img height="25" src="CIVislogo.png" /> Datadog Test Visibility installation script

A script that installs Datadog tracing libraries and prints environment variables necessary for configuring [Datadog Test Visibility](https://docs.datadoghq.com/tests/).
The variables are printed in the following format: variableName=variableValue

Supported languages are .NET, Java, Javascript, and Python.

## About Datadog Test Visibility

[Test Visibility](https://docs.datadoghq.com/tests/) provides a test-first view into your CI health by displaying important metrics and results from your tests. 
It can help you investigate and mitigate performance problems and test failures that are most relevant to your work, focusing on the code you are responsible for, rather than the pipelines which run your tests.

## Usage

Run the script with the necessary parameters:
```shell
DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=... DD_API_KEY=... ./install_test_visibility.sh
```

The script parameters are
- `DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES`: (required) List of languages to be instrumented. Can be either `all` or any of `java`, `js`, `python`, `dotnet` (multiple languages can be specified as a space-separated list).
- `DD_API_KEY`: (required for .NET tracer installation) Datadog API key. Can be found at https://app.datadoghq.com/organization-settings/api-keys
- `DD_TRACER_FOLDER`: (optional) The folder where the tracing libraries will be installed, defaults to `./.datadog`
- `DD_SITE`: (optional) Datadog site, defaults to US1. See https://docs.datadoghq.com/getting_started/site for more information about sites.
- `DD_SET_TRACER_VERSION_DOTNET`: (optional) Version of the .NET tracer to install. If not provided, the latest version is installed.
- `DD_SET_TRACER_VERSION_JAVA`: (optional) Version of the Java tracer to install (without the `v` prefix, e.g. `1.37.1`). If not provided, the latest version is installed.
- `DD_SET_TRACER_VERSION_JS`: (optional) Version of the JS tracer to install. If not provided, the latest version is installed.
- `DD_SET_TRACER_VERSION_PYTHON`: (optional) Version of the Python tracer to install. If not provided, the latest version is installed.
- `DD_INSTRUMENTATION_BUILD_SYSTEM_JAVA`: (optional) A hint for Java instrumentation to instrument a specific build system. Allowed values are `maven` and `gradle`. If not specified, all Java processes will be instrumented.

The script will install the libraries and print the list of environment variables that should be set in order to enable Test Visibility. Example output:
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

### Tracing vitest tests

ℹ️ This section is only relevant if you're running tests with [vitest](https://github.com/vitest-dev/vitest).

To use this script with vitest you need to modify the NODE_OPTIONS environment variable adding the `--import` flag with the value of the `DD_TRACE_ESM_IMPORT` environment variable.

```shell
export NODE_OPTIONS="$NODE_OPTIONS --import=$DD_TRACE_ESM_IMPORT"
```

**Important**: `vitest` and `dd-trace` require Node.js>=18.19 or Node.js>=20.6 to work together.

### Tracing cypress tests

To instrument your [Cypress](https://www.cypress.io/) tests with Datadog Test Visibility, please follow the manual steps in the [docs](https://docs.datadoghq.com/tests/setup/javascript/?tab=cypress).
