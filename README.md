![logo](CIVislogo.png)

# Datadog Test Visibility installation script

A script that installs Datadog tracing libraries and prints environment variables necessary for configuring [Datadog Test Visibility](https://docs.datadoghq.com/tests/).
The variables are printed in the following format: variableName=variableValue

Supported languages are .NET, Java, Javascript, and Python.

## About Datadog Test Visibility

[Test Visibility](https://docs.datadoghq.com/tests/) provides a test-first view into your CI health by displaying important metrics and results from your tests. 
It can help you investigate and mitigate performance problems and test failures that are most relevant to your work, focusing on the code you are responsible for, rather than the pipelines which run your tests.

## Usage

Run the script with the necessary parameters:
```shell
DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=... DD_API_KEY=... ./install_script_civisibility.sh
```

The script parameters are
- `DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES`: (required) List of languages to be instrumented. Can be either `all` or any of `java`, `js`, `python`, `dotnet` (multiple languages can be specified as a space-separated list).
- `DD_API_KEY`: (required) Datadog API key. Can be found at https://app.datadoghq.com/organization-settings/api-keys
- `DD_TRACER_FOLDER`: (optional) The folder where the tracing libraries will be installed, defaults to `./.datadog`
- `DD_SITE`: (optional) Datadog site, defaults to US1. See https://docs.datadoghq.com/getting_started/site for more information about sites.

The script will install the libraries and print the list of environment variables that should be set in order to enable Test Visibility. Example output:
```shell
DD_CIVISIBILITY_ENABLED=true
DD_CIVISIBILITY_AGENTLESS_ENABLED=true
DD_ENV=ci
JAVA_TOOL_OPTIONS=-javaagent:./.datadog/dd-java-agent.jar
```

If you want to set the variables printed by the script, use the following expression:
```shell
export $(DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=... DD_API_KEY=... ./install_script_civisibility.sh | xargs)
```
