# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/)
# Copyright 2024-present Datadog, Inc.

# This script installs Datadog tracing libraries for the specified languages
# and prints to standard output the environment variables that need to be set for enabling Test Visibility.

# The variables are printed in the following format: variableName=variableValue

set -e

ARTIFACTS_FOLDER="${DD_TRACER_FOLDER:-$(pwd)/.datadog}"
if ! mkdir -p $ARTIFACTS_FOLDER; then
  >&2 echo "Error: Cannot create folder: $ARTIFACTS_FOLDER"
  return 1
fi

extract_major_version() {
  echo $1 | cut -d '.' -f 1
}

extract_minor_version() {
  echo $1 | cut -d '.' -f 2
}

install_java_tracer() {
  if [ -z "$DD_SET_TRACER_VERSION_JAVA" ]; then
      DD_SET_TRACER_VERSION_JAVA=$(get_latest_java_tracer_version)
  fi

  local filepath_tracer
  filepath_tracer="$ARTIFACTS_FOLDER/dd-java-agent.jar"
  local filepath_checksum
  filepath_checksum="$ARTIFACTS_FOLDER/dd-java-agent.jar.sha256"

  download_file "https://repo1.maven.org/maven2/com/datadoghq/dd-java-agent/$DD_SET_TRACER_VERSION_JAVA/dd-java-agent-$DD_SET_TRACER_VERSION_JAVA.jar" $filepath_tracer
  download_file "https://repo1.maven.org/maven2/com/datadoghq/dd-java-agent/$DD_SET_TRACER_VERSION_JAVA/dd-java-agent-$DD_SET_TRACER_VERSION_JAVA.jar.sha256" $filepath_checksum

  if ! verify_checksum "$(cat $filepath_checksum)" "$filepath_tracer"; then
    return 1
  fi

  case $DD_INSTRUMENTATION_BUILD_SYSTEM_JAVA in
    gradle)
      echo "GRADLE_OPTS=-javaagent:$filepath_tracer $GRADLE_OPTS"
      ;;
    maven)
      echo "MAVEN_OPTS=-javaagent:$filepath_tracer $MAVEN_OPTS"
      ;;
    sbt)
      echo "SBT_OPTS=-javaagent:$filepath_tracer SBT_OPTS"
      ;;
    ant)
      echo "ANT_OPTS=-javaagent:$filepath_tracer ANT_OPTS"
      ;;
    all)
      local updated_java_tool_options="-javaagent:$filepath_tracer $JAVA_TOOL_OPTIONS"
      if [ ${#updated_java_tool_options} -le 1024 ]; then
        echo "JAVA_TOOL_OPTIONS=$updated_java_tool_options"
      else
        >&2 echo "Error: Cannot apply Java instrumentation: updated JAVA_TOOL_OPTIONS would exceed 1024 characters"
        return 1
      fi
      ;;
    *)
      echo "GRADLE_OPTS=-javaagent:$filepath_tracer $GRADLE_OPTS"
      echo "MAVEN_OPTS=-javaagent:$filepath_tracer $MAVEN_OPTS"
      echo "SBT_OPTS=-javaagent:$filepath_tracer $SBT_OPTS"
      echo "ANT_OPTS=-javaagent:$filepath_tracer $ANT_OPTS"
      ;;
  esac

  echo "DD_TRACER_VERSION_JAVA=$(command -v java >/dev/null 2>&1 && java -jar $filepath_tracer || unzip -p $filepath_tracer META-INF/MANIFEST.MF | grep -i implementation-version | cut -d' ' -f2)"
}

verify_checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    if ! echo "$1 $2" | sha256sum --quiet -c -; then
      return 1
    fi
  elif command -v shasum >/dev/null 2>&1; then
    if ! echo "$1  $2" | shasum --quiet -a 256 -c -; then
      return 1
    fi
  else
    >&2 echo "Error: Neither sha256sum nor shasum is installed."
    return 1
  fi
}

get_latest_java_tracer_version() {
  local filepath_metadata
  filepath_metadata="$ARTIFACTS_FOLDER/maven-metadata.xml"
  local filepath_checksum
  filepath_checksum="$ARTIFACTS_FOLDER/maven-metadata.xml.sha256"

  download_file "https://repo1.maven.org/maven2/com/datadoghq/dd-java-agent/maven-metadata.xml" $filepath_metadata
  download_file "https://repo1.maven.org/maven2/com/datadoghq/dd-java-agent/maven-metadata.xml.sha256" $filepath_checksum

  if ! verify_checksum "$(cat $filepath_checksum)" "$filepath_metadata"; then
    return 1
  fi

  local java_tracer_version
  java_tracer_version=$(grep -o "<latest>.*</latest>" $filepath_metadata | sed -e 's/<[^>]*>//g')

  rm $filepath_metadata $filepath_checksum

  echo "$java_tracer_version"
}

download_file() {
  local url=$1
  local filepath=$2
  if command -v curl >/dev/null 2>&1; then
    curl -Lo "$filepath" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$filepath" "$url"
  else
    >&2 echo "Error: Neither wget nor curl is installed."
    return 1
  fi
}

install_js_tracer() {
  if ! command -v npm >/dev/null 2>&1; then
    >&2 echo "Error: npm is not installed."
    return 1
  fi

  if ! command -v node >/dev/null 2>&1; then
    >&2 echo "Error: node is not installed."
    return 1
  fi

  if ! is_node_version_compliant; then
    >&2 echo "Error: node v18.0.0 or newer is required, got $(node -v)"
    return 1
  fi

  # set location for installing global packages (the script may not have the permissions to write to the default one)
  export NPM_CONFIG_PREFIX=$ARTIFACTS_FOLDER

  # install dd-trace as a "global" package
  # (otherwise, doing SCM checkout might rollback the changes to package.json, and any subsequent `npm install` calls will result in removing the package)
  if ! npm install -g dd-trace${DD_SET_TRACER_VERSION_JS:+@$DD_SET_TRACER_VERSION_JS} >&2; then
    >&2 echo "Error: Could not install dd-trace for JS"
    return 1
  fi

  # Github Actions prohibit setting NODE_OPTIONS
  local dd_trace_ci_init_path="$ARTIFACTS_FOLDER/lib/node_modules/dd-trace/ci/init"
  local dd_trace_register_path="$ARTIFACTS_FOLDER/lib/node_modules/dd-trace/register.js"
  if ! is_github_actions; then
    echo "NODE_OPTIONS=$NODE_OPTIONS -r $dd_trace_ci_init_path"
  else
    echo "DD_TRACE_PACKAGE=$dd_trace_ci_init_path"
  fi
  # We can't set the --import flag directly in NODE_OPTIONS since it's only compatible from Node.js>=20.6.0 and Node.js>=18.19,
  # not even if !is_github_actions.
  # Additionally, it's not useful for test frameworks other than vitest, which is ESM first.
  echo "DD_TRACE_ESM_IMPORT=$dd_trace_register_path"

  echo "DD_TRACER_VERSION_JS=$(npm list -g dd-trace | grep dd-trace | awk -F@ '{print $2}')"
}

is_node_version_compliant() {
  local node_version
  node_version=$(node -v | cut -d 'v' -f 2)

  local major_node_version
  major_node_version=$(echo $node_version | cut -d '.' -f 1)

  if [ "$major_node_version" -lt 18 ]; then
    return 1
  fi
}

is_github_actions() {
  if [ -z "$GITHUB_ACTION" ]; then
    return 1
  fi
}

install_python_tracer() {
  if ! command -v pip >/dev/null 2>&1; then
    >&2 echo "Error: pip is not installed."
    return 1
  fi

  python -m venv .dd_civis_env >&2
  source .dd_civis_env/bin/activate >&2

  if ! pip install -U ddtrace${DD_SET_TRACER_VERSION_PYTHON:+==$DD_SET_TRACER_VERSION_PYTHON} coverage >&2; then
    >&2 echo "Error: Could not install ddtrace for Python"
    return 1
  fi

  local dd_trace_path
  dd_trace_path=$(pip show ddtrace | grep Location | awk '{print $2}')
  if ! [ -d $dd_trace_path ]; then
    >&2 echo "Error: Could not determine ddtrace package location (tried $dd_trace_path)"
    return 1
  fi

  local coverage_path
  coverage_path=$(pip show coverage | grep Location | awk '{print $2}')
  if ! [ -d $coverage_path ]; then
    >&2 echo "Error: Could not determine coverage package location (tried $coverage_path)"
    return 1
  fi

  echo "PYTHONPATH=$dd_trace_path:$coverage_path:$PYTHONPATH"
  echo "PYTEST_ADDOPTS=--ddtrace $PYTEST_ADDOPTS"

  echo "DD_TRACER_VERSION_PYTHON=$(pip show ddtrace | grep Version | cut -d ' ' -f2)"

  deactivate >&2
}

install_dotnet_tracer() {
  if ! command -v dotnet >/dev/null 2>&1; then
    >&2 echo "Error: dotnet is not installed."
    return 1
  fi

  if ! dotnet tool update --tool-path $ARTIFACTS_FOLDER dd-trace ${DD_SET_TRACER_VERSION_DOTNET:+--version $DD_SET_TRACER_VERSION_DOTNET} >&2; then
    >&2 echo "Error: Could not install dd-trace for .NET"
    return 1
  fi

  if [ -z "$DD_API_KEY" ]; then
    >&2 echo "Error: dd-trace for .NET configuration requires DD_API_KEY to be set"
    return 1
  fi

  # Using "jenkins" for now, as it outputs the env vars in a provider-agnostic format.
  # Grepping to filter out lines that are not environment variables
  DD_CIVISIBILITY_AGENTLESS_ENABLED=true $ARTIFACTS_FOLDER/dd-trace ci configure jenkins | grep '='

  echo "DD_TRACER_VERSION_DOTNET=$(dotnet tool list --tool-path $ARTIFACTS_FOLDER | grep dd-trace | awk '{print $2}')"
}

is_ruby_version_compliant() {
  local ruby_version
  ruby_version=$(ruby -v | cut -d ' ' -f 2)

  local major_ruby_version
  local minor_ruby_version

  major_ruby_version=$(extract_major_version $ruby_version)
  minor_ruby_version=$(extract_minor_version $ruby_version)

  if [ "$major_ruby_version" -lt 2 ] || [ "$major_ruby_version" -eq 2 ] && [ "$minor_ruby_version" -lt 7 ]; then
    return 1
  fi
}

is_rubygems_version_compliant() {
  local rubygems_version
  rubygems_version=$(gem -v)

  local major_rubygems_version
  local minor_rubygems_version

  major_rubygems_version=$(extract_major_version $rubygems_version)
  minor_rubygems_version=$(extract_minor_version $rubygems_version)

  if [ "$major_rubygems_version" -lt 3 ] || [ "$major_rubygems_version" -eq 3 ] && [ "$minor_rubygems_version" -lt 3 ]; then
    return 1
  fi
}

is_datadog_ci_present() {
  if ! bundle info datadog-ci >/dev/null 2>&1 ; then
    return 1
  fi
}

is_datadog_ci_version_compliant() {
  if ! is_datadog_ci_present; then
    >&2 echo "datadog-ci is not present"
    return 1
  fi

  local datadog_ci_version
  datadog_ci_version=$(bundle info datadog-ci | head -n 1 | awk -F '[()]' '{print $2}')

  local major_datadog_ci_version
  local minor_datadog_ci_version

  major_datadog_ci_version=$(extract_major_version $datadog_ci_version)
  minor_datadog_ci_version=$(extract_minor_version $datadog_ci_version)

  if [ "$major_datadog_ci_version" -lt 1 ] || [ "$major_datadog_ci_version" -eq 1 ] && [ "$minor_datadog_ci_version" -lt 9 ]; then
    return 1
  fi
}

install_ruby_tracer() {
  if ! command -v ruby >/dev/null 2>&1; then
    >&2 echo "Error: ruby is not installed."
    return 1
  fi

  if ! command -v bundle >/dev/null 2>&1; then
    >&2 echo "Error: bundler is not installed."
    return 1
  fi

  if ! command -v gem >/dev/null 2>&1; then
    >&2 echo "Error: rubygems is not installed."
    return 1
  fi

  if ! is_ruby_version_compliant; then
    >&2 echo "Error: ruby v2.7.0 or newer is required, got $(ruby -v)"
    return 1
  fi

  if ! is_rubygems_version_compliant; then
    >&2 echo "Error: rubygems v3.3.22 or newer is required, got $(gem -v)"
    return 1
  fi

  # we need to "unfreeze" bundle to install the datadog-ci gem
  if ! bundle config set frozen false >&2; then
    >&2 echo "Error: Could not unfreeze bundle"
    return 1
  fi

  # datadog-ci gem must be part of Gemfile.lock to load it within bundled environment
  if ! bundle add datadog-ci ${DD_SET_TRACER_VERSION_RUBY:+-v $DD_SET_TRACER_VERSION_RUBY} >&2; then
    >&2 echo "Error: Could not install datadog-ci gem for Ruby"
    return 1
  fi

  # check that datadog-ci version installed if at least 1.9.0 (when auto instrumentation was introduced)
  if ! is_datadog_ci_version_compliant; then
    >&2 echo "Error: datadog-ci v1.9.0 or newer is required, got $(bundle show datadog-ci)"
    return 1
  fi

  echo "RUBYOPT=-rbundler/setup -rdatadog/ci/auto_instrument"
}

# set common environment variables
echo "DD_CIVISIBILITY_ENABLED=true"
echo "DD_CIVISIBILITY_AGENTLESS_ENABLED=true"

if [ -z "$DD_ENV" ]; then
  echo "DD_ENV=ci"
fi

# install tracer libraries
if [ -n "$DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES" ]; then
  if [ "$DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES" = "all" ]; then
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES="java js python dotnet ruby"
  fi

  for lang in $( echo "$DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES" )
  do
    case $lang in
      java)
        install_java_tracer
        ;;
      js)
        install_js_tracer
        ;;
      python)
        install_python_tracer
        ;;
      dotnet)
        install_dotnet_tracer
        ;;
      ruby)
        install_ruby_tracer
        ;;
      *)
        >&2 echo "Unknown language: $lang. Must be one of: java, js, python, dotnet, ruby"
        exit 1;
        ;;
    esac
  done
else
  >&2 echo "Error: DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES environment variable should be set to all or a space-separated subset of java, js, python, dotnet, ruby"
  exit 1;
fi
