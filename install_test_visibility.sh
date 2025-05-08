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
  echo "$1" | cut -d '.' -f 1
}

extract_minor_version() {
  echo "$1" | cut -d '.' -f 2
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

  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "winnt" ]]; then
    . .dd_civis_env/Scripts/activate >&2
  else
    source .dd_civis_env/bin/activate >&2
  fi

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

  # Uninstall any previous global installation of dd-trace.
  # Ignore errors if the tool is not installed.
  dotnet tool uninstall --global dd-trace >/dev/null 2>&1 || true

  # Uninstall any previous local installation of dd-trace in the artifacts folder.
  # Again, ignore errors if not installed.
  dotnet tool uninstall --tool-path $ARTIFACTS_FOLDER dd-trace >/dev/null 2>&1 || true

  # Update (or install) dd-trace in the artifacts folder.
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

  major_ruby_version=$(extract_major_version "$ruby_version")
  minor_ruby_version=$(extract_minor_version "$ruby_version")

  if [ "$major_ruby_version" -lt 2 ] || ([ "$major_ruby_version" -eq 2 ] && [ "$minor_ruby_version" -lt 7 ]); then
    return 1
  fi
}

is_rubygems_version_compliant() {
  local rubygems_version
  rubygems_version=$(gem -v)

  local major_rubygems_version
  local minor_rubygems_version

  major_rubygems_version=$(extract_major_version "$rubygems_version")
  minor_rubygems_version=$(extract_minor_version "$rubygems_version")

  if [ "$major_rubygems_version" -lt 3 ] || ([ "$major_rubygems_version" -eq 3 ] && [ "$minor_rubygems_version" -lt 3 ]); then
    return 1
  fi
}

is_gem_present() {
  if ! bundle info $1 >/dev/null 2>&1 ; then
    return 1
  fi
}

is_gem_datadog_version_compliant() {
  # if there is no datadog gem in the bundle, it's ok, we are going to add it
  if ! is_gem_present "datadog"; then
    return 0
  fi

  local datadog_version
  datadog_version=$(bundle info datadog | head -n 1 | awk -F '[()]' '{print $2}')

  local major_datadog_version
  local minor_datadog_version

  major_datadog_version=$(extract_major_version "$datadog_version")
  minor_datadog_version=$(extract_minor_version "$datadog_version")

  if [ "$major_datadog_version" -eq 2 ] && [ "$minor_datadog_version" -lt 4 ]; then
    return 1
  fi
}

datadog_ci_gem_version() {
  bundle info datadog-ci | head -n 1 | awk -F '[()]' '{print $2}'
}

is_datadog_ci_version_compliant() {
  if ! is_gem_present "datadog-ci"; then
    return 1
  fi

  local datadog_ci_version
  datadog_ci_version=$(datadog_ci_gem_version)

  local major_datadog_ci_version
  local minor_datadog_ci_version

  major_datadog_ci_version=$(extract_major_version "$datadog_ci_version")
  minor_datadog_ci_version=$(extract_minor_version "$datadog_ci_version")

  if [ "$major_datadog_ci_version" -lt 1 ] || ([ "$major_datadog_ci_version" -eq 1 ] && [ "$minor_datadog_ci_version" -lt 9 ]); then
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

  if is_gem_present "ddtrace"; then
    >&2 echo "Error: ddtrace gem is incompatible with datadog-ci gem. Please upgrade to gem datadog v2.4 or newer: https://github.com/DataDog/dd-trace-rb/blob/master/docs/UpgradeGuide2.md"
    return 1
  fi

  if ! is_gem_datadog_version_compliant; then
    >&2 echo "Error: datadog gem v2.4 or newer is required, got $(bundle show datadog)"
    return 1
  fi

  # add datadog-ci gem to the bundle only if it's not already present
  if ! is_gem_present "datadog-ci"; then
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
  fi

  # check that datadog-ci version installed if at least 1.9.0 (when auto instrumentation was introduced)
  if ! is_datadog_ci_version_compliant; then
    >&2 echo "Error: datadog-ci v1.9.0 or newer is required, got $(bundle show datadog-ci)"
    return 1
  fi

  echo "RUBYOPT=-rbundler/setup -rdatadog/ci/auto_instrument"
  echo "DD_TRACER_VERSION_RUBY=$(datadog_ci_gem_version)"
}

# Function to get the Go version from the go.mod file of a release
get_orchestrion_go_version() {
    local input_tag="$1"
    local tag=""

    # If "latest" is provided, fetch the latest release tag from GitHub API
    if [ "$input_tag" == "latest" ]; then
        # Use curl with -sSf to ensure errors are caught and not output to stdout
        # Use grep and sed to extract the tag_name from the JSON response
        tag=$(curl -sSf -A "github-action" https://api.github.com/repos/datadog/orchestrion/releases/latest \
              | grep -o '"tag_name": *"[^"]*"' \
              | head -n 1 \
              | sed 's/"tag_name": *"\([^"]*\)"/\1/')
        if [ -z "$tag" ]; then
            echo "Error: Could not retrieve the latest tag." >&2
            return 1
        fi
    else
        tag="$input_tag"
    fi

    # Determine the URL to fetch the go.mod file
    local url=""
    # If tag looks like a commit SHA (7 to 40 hexadecimal characters)
    if [[ "$tag" =~ ^[0-9a-f]{7,40}$ ]]; then
        url="https://raw.githubusercontent.com/DataDog/orchestrion/${tag}/go.mod"
    else
        url="https://raw.githubusercontent.com/DataDog/orchestrion/refs/tags/${tag}/go.mod"
    fi

    # Fetch the go.mod file content using curl with -sSf
    local go_mod
    go_mod=$(curl -sSf -A "github-action" "$url" || true)
    if [ -z "$go_mod" ]; then
        echo "Error: Could not retrieve go.mod from ${url}" >&2
        return 1
    fi

    # Extract the Go version by searching for the line starting with "go "
    local go_version
    go_version=$(echo "$go_mod" | grep -m 1 '^go ' | awk '{print $2}')
    if [ -z "$go_version" ]; then
        echo "Error: Could not extract the Go version from go.mod" >&2
        return 1
    fi

    echo "$go_version"
}

# Helper function to compare two semantic version numbers.
# It returns 0 (true) if the first version ($1) is greater than or equal to the second ($2),
# and returns 1 (false) otherwise.
version_ge() {
    # Split version numbers into arrays based on the dot separator
    IFS='.' read -r -a ver1 <<< "$1"
    IFS='.' read -r -a ver2 <<< "$2"

    # Determine the maximum length of both version arrays
    local len=${#ver1[@]}
    if [ ${#ver2[@]} -gt $len ]; then
        len=${#ver2[@]}
    fi

    # Compare each numeric segment of the version
    for (( i=0; i<len; i++ )); do
        # Use 0 as default if the segment is missing
        local num1=${ver1[i]:-0}
        local num2=${ver2[i]:-0}
        if (( num1 > num2 )); then
            return 0  # installed version is greater
        elif (( num1 < num2 )); then
            return 1  # installed version is lower
        fi
    done
    # They are equal
    return 0
}

# Function to check if the installed Go version meets the requirement.
# It calls get_go_version with a provided parameter (tag name or "latest"),
# extracts the installed version from `go version`, and compares both.
# Returns "true" if installed Go version >= required version, "false" otherwise.
check_go_version_requirement() {
    local tag_param="$1"
    local required_version

    # Get the required Go version from the release go.mod file
    required_version=$(get_orchestrion_go_version "$tag_param")
    if [ $? -ne 0 ]; then
        echo "Error retrieving required version" >&2
        echo "false"  # Consistently output false in case of error
        return 0     # Optionally return 0 to indicate successful processing of output
    fi

    # Extract installed Go version.
    local installed_version
    installed_version=$(go version | awk '{print $3}' | sed 's/^go//')

    # Use version_ge to compare the installed and required versions
    if version_ge "$installed_version" "$required_version"; then
         echo "true"
    else
         echo "false"
    fi
}

install_go_tracer() {
  # Check if go is installed
  if ! command -v go >/dev/null 2>&1; then
    >&2 echo "Error: go is not installed."
    return 1
  fi

  if [ -z "$DD_SET_TRACER_VERSION_GO" ]; then
      DD_SET_TRACER_VERSION_GO=latest
  fi

  # Try to retrieve the required Go version from orchestrion's go.mod file using the specified tag.
  local orchestrion_go_version
  orchestrion_go_version=$(get_orchestrion_go_version "$DD_SET_TRACER_VERSION_GO" || true)
  if [ $? -ne 0 ] || [ -z "$orchestrion_go_version" ]; then
      echo "Error: Could not retrieve the required Go version for orchestrion (tag: $DD_SET_TRACER_VERSION_GO)." >&2
      echo "Skipping orchestrion installation." >&2
      return 0
  fi

  # Get the installed Go version (e.g., "1.24.0" from "go version go1.24.0 darwin/arm64")
  local installed_go_version
  installed_go_version=$(go version | awk '{print $3}' | sed 's/^go//')

  # Compare the installed version with the required version.
  if ! version_ge "$installed_go_version" "$orchestrion_go_version"; then
      echo "The installed Go version ($installed_go_version) does not meet the required version ($orchestrion_go_version) for orchestrion (tag: $DD_SET_TRACER_VERSION_GO)." >&2
      echo "Skipping orchestrion installation." >&2
      return 0
  fi

  # Install orchestrion using go install
  if ! go install github.com/DataDog/orchestrion@$DD_SET_TRACER_VERSION_GO >&2; then
    >&2 echo "Error: Could not install orchestrion for Go."
    return 1
  fi

  # Pin orchestrion
  if ! orchestrion pin >&2; then
    >&2 echo "Error: Orchestrion pin failed."
    return 1
  fi

  # Run go get to update dependencies
  if ! go get github.com/DataDog/orchestrion >&2; then
    >&2 echo "Error: go get github.com/DataDog/orchestrion failed."
    return 1
  fi

  # Append orchestrion to the GOFLAGS variable to enable Test Optimization.
  echo "GOFLAGS=${GOFLAGS} '-toolexec=orchestrion toolexec'"

  # Retrieve orchestrion version and extract only the version part.
  local orchestrion_output
  orchestrion_output=$(orchestrion version 2>/dev/null || echo "orchestrion vlatest")
  # The output is expected to be like: "orchestrion v1.0.2"
  local orchestrion_version
  orchestrion_version=$(echo "$orchestrion_output" | awk '{print $2}')
  echo "DD_TRACER_VERSION_GO=${orchestrion_version}"
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
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES="java js python dotnet ruby go"
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
      go)
        install_go_tracer
        ;;
      *)
        >&2 echo "Unknown language: $lang. Must be one of: java, js, python, dotnet, ruby, go"
        exit 1;
        ;;
    esac
  done
else
  >&2 echo "Error: DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES environment variable should be set to all or a space-separated subset of java, js, python, dotnet, ruby, go"
  exit 1;
fi
