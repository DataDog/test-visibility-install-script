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

#
# Resolve the user-provided orchestrion selector to a single concrete tag so
# the rest of the installation flow uses one stable orchestrion version.
resolve_orchestrion_tag() {
    local input_tag="$1"

    # Reuse explicitly requested tags as-is.
    if [ "$input_tag" != "latest" ]; then
        echo "$input_tag"
        return 0
    fi

    # Resolve "latest" once through the GitHub releases API so the rest of the
    # installation flow works with a single concrete orchestrion version.
    local tag
    tag=$(curl -sSf -A "github-action" https://api.github.com/repos/datadog/orchestrion/releases/latest \
          | grep -o '"tag_name": *"[^"]*"' \
          | head -n 1 \
          | sed 's/"tag_name": *"\([^"]*\)"/\1/')
    if [ -z "$tag" ]; then
        echo "Error: Could not retrieve the latest tag." >&2
        return 1
    fi

    echo "$tag"
}

#
# Download the requested orchestrion go.mod file from GitHub so later helpers
# can read the dependency versions that shipped with that release.
fetch_orchestrion_go_mod() {
    local tag="$1"
    local modfile="${2:-go.mod}"
    local url=""

    # Support both released tags and direct commit SHAs so the script can keep
    # working with the same kinds of inputs accepted by `go install`.
    if [[ "$tag" =~ ^[0-9a-f]{7,40}$ ]]; then
        url="https://raw.githubusercontent.com/DataDog/orchestrion/${tag}/${modfile}"
    else
        url="https://raw.githubusercontent.com/DataDog/orchestrion/refs/tags/${tag}/${modfile}"
    fi

    # Read the upstream go.mod file directly from GitHub so we can reuse the
    # versions that shipped with the selected orchestrion release.
    local go_mod
    go_mod=$(curl -sSf -A "github-action" "$url" || true)
    if [ -z "$go_mod" ]; then
        echo "Error: Could not retrieve ${modfile} from ${url}" >&2
        return 1
    fi

    echo "$go_mod"
}

# Function to get the Go version from the go.mod file of a release
get_orchestrion_go_version() {
    local input_tag="$1"

    local tag
    tag=$(resolve_orchestrion_tag "$input_tag") || return 1

    local go_mod
    go_mod=$(fetch_orchestrion_go_mod "$tag") || return 1

    # Extract the Go version by searching for the line starting with "go "
    local go_version
    go_version=$(echo "$go_mod" | grep -m 1 '^go ' | awk '{print $2}')
    if [ -z "$go_version" ]; then
        echo "Error: Could not extract the Go version from go.mod" >&2
        return 1
    fi

    echo "$go_version"
}

get_orchestrion_module_version() {
    local input_tag="$1"
    local module_path="$2"
    local modfile="${3:-go.mod}"

    # Resolve the orchestrion tag first so every lookup in this run points to
    # the same upstream revision.
    local tag
    tag=$(resolve_orchestrion_tag "$input_tag") || return 1

    local go_mod
    go_mod=$(fetch_orchestrion_go_mod "$tag" "$modfile") || return 1

    # Extract the version from the relevant require line in the selected go.mod.
    local module_version
    module_version=$(echo "$go_mod" | awk -v module_path="$module_path" '$1 == module_path { print $2; exit }')
    if [ -z "$module_version" ]; then
        echo "Error: Could not extract ${module_path} version from ${modfile}" >&2
        return 1
    fi

    echo "$module_version"
}

#
# Read the target project's Go directive from go.mod so tracer selection can
# stay within the Go version the project already declares.
get_current_project_go_version() {
    local go_mod_path="${1:-go.mod}"

    if [ ! -f "$go_mod_path" ]; then
        echo "Error: Could not find ${go_mod_path} in the current directory." >&2
        return 1
    fi

    # Read the Go directive from the target project so later version selection
    # can stay within the Go level the project already declares.
    local go_version
    go_version=$(grep -m 1 '^go ' "$go_mod_path" | awk '{print $2}')
    if [ -z "$go_version" ]; then
        echo "Error: Could not extract the Go version from ${go_mod_path}" >&2
        return 1
    fi

    echo "$go_version"
}

resolve_go_module_directory() {
    local configured_module_dir="${DD_CIVISIBILITY_GO_MODULE_DIR:-}"

    # An explicit override is user intent, so validate it strictly instead of
    # silently ignoring it.
    if [ -n "$configured_module_dir" ]; then
        if [ ! -d "$configured_module_dir" ]; then
            echo "Error: DD_CIVISIBILITY_GO_MODULE_DIR points to a directory that does not exist: $configured_module_dir" >&2
            return 1
        fi

        local absolute_configured_module_dir
        absolute_configured_module_dir=$(cd "$configured_module_dir" && pwd)
        if [ ! -f "$absolute_configured_module_dir/go.mod" ]; then
            echo "Error: DD_CIVISIBILITY_GO_MODULE_DIR does not contain a go.mod file: $absolute_configured_module_dir" >&2
            return 1
        fi

        echo "$absolute_configured_module_dir"
        return 0
    fi

    # When the script already runs in the module root, keep using the current
    # directory and avoid extra filesystem scanning.
    if [ -f "go.mod" ]; then
        pwd
        return 0
    fi

    # For repository roots that do not contain go.mod directly, auto-detect a
    # single nested module. If there is more than one candidate, do not guess.
    local -a go_mod_candidates=()
    # Collect the detected go.mod paths into an array using syntax that works
    # on the Bash 3.2 shell shipped on macOS GitHub runners.
    while IFS= read -r go_mod_candidate; do
        go_mod_candidates+=("$go_mod_candidate")
    done < <(
        find . \
            \( -path '*/.git' -o -path '*/vendor' -o -path '*/node_modules' \) -prune -o \
            -type f -name go.mod -print \
            | sort
    )

    if [ ${#go_mod_candidates[@]} -eq 1 ]; then
        local detected_module_dir
        detected_module_dir=$(dirname "${go_mod_candidates[0]}")
        (cd "$detected_module_dir" && pwd)
        return 0
    fi

    if [ ${#go_mod_candidates[@]} -eq 0 ]; then
        return 2
    fi

    return 3
}

#
# List the published stable dd-trace-go/v2 releases so the installer can pick
# the newest compatible tracer without considering prerelease tags.
list_stable_dd_trace_go_versions() {
    local module_dir="${1:-.}"

    # Query the published v2 module versions and keep only stable x.y.z tags.
    # This intentionally skips rc/dev builds so the script selects the newest
    # supported released tracer version instead of a pre-release.
    (
        cd "$module_dir" &&
        go list -m -versions github.com/DataDog/dd-trace-go/v2 2>/dev/null \
            | awk '{for (i = 2; i <= NF; i++) print $i}' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'
    )
}

fetch_dd_trace_go_orchestrion_all_go_mod() {
    local version="$1"
    local url="https://raw.githubusercontent.com/DataDog/dd-trace-go/${version}/orchestrion/all/go.mod"

    # Read the integration module metadata directly from GitHub because
    # `orchestrion pin` ultimately adds this module to go.mod.
    local go_mod
    go_mod=$(curl -sSf -A "github-action" "$url" || true)
    if [ -z "$go_mod" ]; then
        echo "Error: Could not retrieve orchestrion/all/go.mod from ${url}" >&2
        return 1
    fi

    echo "$go_mod"
}

#
# Read the Go directive from dd-trace-go's orchestrion/all module for a given
# tracer version so we can check whether that tracer is compatible.
get_dd_trace_go_orchestrion_all_go_version() {
    local version="$1"

    local go_mod
    go_mod=$(fetch_dd_trace_go_orchestrion_all_go_mod "$version") || return 1

    # Extract the Go directive that tells us whether this tracer release can be
    # used without requiring a newer Go version than the project or runner has.
    local go_version
    go_version=$(echo "$go_mod" | grep -m 1 '^go ' | awk '{print $2}')
    if [ -z "$go_version" ]; then
        echo "Error: Could not extract the Go version from orchestrion/all/go.mod for ${version}" >&2
        return 1
    fi

    echo "$go_version"
}

# Helper function to compare two semantic version numbers.
# It returns 0 (true) if the first version ($1) is greater than or equal to the second ($2),
# and returns 1 (false) otherwise.
version_ge() {
    local normalized_version_1="${1#v}"
    local normalized_version_2="${2#v}"
    normalized_version_1="${normalized_version_1%%-*}"
    normalized_version_2="${normalized_version_2%%-*}"
    normalized_version_1="${normalized_version_1%%+*}"
    normalized_version_2="${normalized_version_2%%+*}"

    # Split version numbers into arrays based on the dot separator
    IFS='.' read -r -a ver1 <<< "$normalized_version_1"
    IFS='.' read -r -a ver2 <<< "$normalized_version_2"

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

#
# Return the lower of two semantic versions so tracer selection can use the
# stricter compatibility ceiling between the project and the runner.
version_min() {
    if version_ge "$1" "$2"; then
        echo "$2"
    else
        echo "$1"
    fi
}

#
# Pick the newest stable dd-trace-go release that is not older than the
# orchestrion-shipped baseline and whose orchestrion/all module still supports
# the effective Go ceiling for this project and runner.
select_dd_trace_go_version_for_project() {
    local minimum_version="$1"
    local max_supported_go_version="$2"
    local module_dir="${3:-.}"

    local -a available_versions=()
    # Collect the published stable tracer versions into an array using syntax
    # that works on the Bash 3.2 shell shipped on macOS GitHub runners.
    while IFS= read -r available_version; do
        available_versions+=("$available_version")
    done < <(list_stable_dd_trace_go_versions "$module_dir")
    if [ ${#available_versions[@]} -eq 0 ]; then
        echo "Error: Could not retrieve the list of stable dd-trace-go versions." >&2
        return 1
    fi

    # Selection algorithm:
    # - Start from the newest stable dd-trace-go release.
    # - Reject anything older than the orchestrion-shipped baseline.
    # - For each remaining candidate, read orchestrion/all/go.mod and keep the
    #   first release whose Go requirement fits within the effective Go ceiling.
    # The first match is the newest stable tracer that is both safe for the
    # selected orchestrion release and compatible with this project + runner.
    # Walk the stable releases from newest to oldest and pick the first one
    # that satisfies both constraints:
    # 1. It is not older than the version shipped with the selected orchestrion.
    # 2. Its orchestrion/all module does not require a newer Go version than
    #    the project and runner can support together.
    local candidate_version
    local candidate_go_version
    local index
    for (( index=${#available_versions[@]}-1; index>=0; index-- )); do
        candidate_version="${available_versions[index]}"

        if ! version_ge "$candidate_version" "$minimum_version"; then
            continue
        fi

        candidate_go_version=$(get_dd_trace_go_orchestrion_all_go_version "$candidate_version" 2>/dev/null || true)
        if [ -z "$candidate_go_version" ]; then
            continue
        fi

        if version_ge "$max_supported_go_version" "$candidate_go_version"; then
            echo "$candidate_version"
            return 0
        fi
    done

    return 1
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

  # Resolve the input to a concrete orchestrion tag once so "latest" does not
  # drift between the different network calls below.
  local resolved_orchestrion_tag
  resolved_orchestrion_tag=$(resolve_orchestrion_tag "$DD_SET_TRACER_VERSION_GO" || true)
  if [ $? -ne 0 ] || [ -z "$resolved_orchestrion_tag" ]; then
      echo "Error: Could not resolve the orchestrion tag for $DD_SET_TRACER_VERSION_GO." >&2
      return 1
  fi

  # Try to retrieve the required Go version from orchestrion's go.mod file using the specified tag.
  local orchestrion_go_version
  orchestrion_go_version=$(get_orchestrion_go_version "$resolved_orchestrion_tag" || true)
  if [ $? -ne 0 ] || [ -z "$orchestrion_go_version" ]; then
      echo "Error: Could not retrieve the required Go version for orchestrion (tag: $resolved_orchestrion_tag)." >&2
      echo "Skipping orchestrion installation." >&2
      return 0
  fi

  # Get the installed Go version (e.g., "1.24.0" from "go version go1.24.0 darwin/arm64")
  local installed_go_version
  installed_go_version=$(go version | awk '{print $3}' | sed 's/^go//')

  # Compare the installed version with the required version.
  if ! version_ge "$installed_go_version" "$orchestrion_go_version"; then
      echo "The installed Go version ($installed_go_version) does not meet the required version ($orchestrion_go_version) for orchestrion (tag: $resolved_orchestrion_tag)." >&2
      echo "Skipping orchestrion installation." >&2
      return 0
  fi

  # Resolve the Go module directory before touching go.mod. The script first
  # honors an explicit override, then tries the current directory, then falls
  # back to single-module auto-detection for repository roots that only contain
  # a nested Go project.
  local go_module_dir
  local module_resolution_status
  if go_module_dir=$(resolve_go_module_directory); then
      module_resolution_status=0
  else
      module_resolution_status=$?
  fi
  if [ $module_resolution_status -eq 1 ]; then
      return 1
  fi
  if [ $module_resolution_status -ne 0 ] || [ -z "$go_module_dir" ]; then
      if [ $module_resolution_status -eq 2 ]; then
          >&2 echo "Could not find a go.mod file in the current directory or any nested directory."
      else
          >&2 echo "Could not determine a single Go module directory automatically."
          >&2 echo "Set DD_CIVISIBILITY_GO_MODULE_DIR to the Go module root if this repository contains multiple Go modules."
      fi
      >&2 echo "Skipping orchestrion installation."
      return 0
  fi

  # The selected orchestrion release defines the minimum tracer version we can
  # use safely. We never choose anything older than this baseline.
  local minimum_dd_trace_go_version
  minimum_dd_trace_go_version=$(get_orchestrion_module_version "$resolved_orchestrion_tag" "github.com/DataDog/dd-trace-go/v2" || true)
  if [ $? -ne 0 ] || [ -z "$minimum_dd_trace_go_version" ]; then
      >&2 echo "Error: Could not retrieve the dd-trace-go version for orchestrion (tag: $resolved_orchestrion_tag)."
      return 1
  fi

  # The shipped minimum tracer version can itself require a newer Go version
  # through its orchestrion/all module. We use this requirement as the hard
  # lower bound for deciding whether a project can be instrumented at all.
  local minimum_dd_trace_go_required_go_version
  minimum_dd_trace_go_required_go_version=$(get_dd_trace_go_orchestrion_all_go_version "$minimum_dd_trace_go_version" || true)
  if [ $? -ne 0 ] || [ -z "$minimum_dd_trace_go_required_go_version" ]; then
      >&2 echo "Error: Could not retrieve the Go requirement for dd-trace-go $minimum_dd_trace_go_version."
      return 1
  fi

  # The runner also needs to satisfy the minimum tracer requirement. This check
  # is stricter than the earlier orchestrion root go.mod check and protects the
  # fallback path if the tracer bundle starts requiring a newer Go version than
  # orchestrion's root module declares.
  if ! version_ge "$installed_go_version" "$minimum_dd_trace_go_required_go_version"; then
      >&2 echo "The installed Go version ($installed_go_version) is lower than the minimum Go version required by dd-trace-go $minimum_dd_trace_go_version ($minimum_dd_trace_go_required_go_version)."
      >&2 echo "Skipping orchestrion installation."
      return 0
  fi

  # Use the lower of the project's Go directive and the runner's installed Go
  # version as the compatibility ceiling. This keeps the selected tracer inside
  # the Go version already declared by the project and also avoids picking a
  # module that the current runner cannot build.
  local selected_dd_trace_go_version
  selected_dd_trace_go_version="$minimum_dd_trace_go_version"

  # Prefer the newest compatible tracer when we can read the project's Go
  # version from the selected module root. If that information is unavailable
  # or does not lead to a compatible release, fall back to the minimum tracer
  # version that shipped with orchestrion so the script still avoids floating to
  # an unsupported `dd-trace-go@latest`.
  local project_go_version
  if project_go_version=$(get_current_project_go_version "$go_module_dir/go.mod"); then
      # If the project itself declares a Go version below the minimum required by
      # the shipped tracer, do not fall back to that tracer. Skipping here avoids
      # letting `orchestrion pin` silently move the project to a newer Go level.
      if ! version_ge "$project_go_version" "$minimum_dd_trace_go_required_go_version"; then
          >&2 echo "The project Go version ($project_go_version) is lower than the minimum Go version required by dd-trace-go $minimum_dd_trace_go_version ($minimum_dd_trace_go_required_go_version)."
          >&2 echo "Skipping orchestrion installation."
          return 0
      fi

      local max_supported_go_version
      max_supported_go_version=$(version_min "$project_go_version" "$installed_go_version")

      # Choose the newest stable tracer release that satisfies the two
      # boundaries: it must be at least the version shipped with orchestrion,
      # and its orchestrion/all module must support the effective Go ceiling
      # computed above.
      local compatible_dd_trace_go_version
      if compatible_dd_trace_go_version=$(select_dd_trace_go_version_for_project "$minimum_dd_trace_go_version" "$max_supported_go_version" "$go_module_dir"); then
          selected_dd_trace_go_version="$compatible_dd_trace_go_version"
      else
          >&2 echo "Could not find a project-compatible stable dd-trace-go release for Go $max_supported_go_version."
          >&2 echo "Falling back to the minimum dd-trace-go version shipped with orchestrion: $minimum_dd_trace_go_version."
      fi
  else
      >&2 echo "Could not read the project Go version from $go_module_dir/go.mod."
      >&2 echo "Falling back to the minimum dd-trace-go version shipped with orchestrion: $minimum_dd_trace_go_version."
  fi

  # Install the requested orchestrion CLI version in GOPATH/bin so the later
  # `orchestrion pin` command runs with the same release we just resolved.
  if ! go install github.com/DataDog/orchestrion@$resolved_orchestrion_tag >&2; then
    >&2 echo "Error: Could not install orchestrion for Go."
    return 1
  fi

  # Pin dd-trace-go only after the orchestrion CLI is available so install
  # failures do not leave the customer's go.mod partially updated.
  if ! (cd "$go_module_dir" && go mod edit -require=github.com/DataDog/dd-trace-go/v2@$selected_dd_trace_go_version) >&2; then
    >&2 echo "Error: Could not pin dd-trace-go for Go to version $selected_dd_trace_go_version."
    return 1
  fi

  # Generate/update orchestrion.tool.go and the project dependencies. At this
  # point dd-trace-go is already pinned in go.mod, so orchestrion will reuse
  # that version instead of upgrading to the latest tracer release.
  if ! (cd "$go_module_dir" && orchestrion pin) >&2; then
    >&2 echo "Error: Orchestrion pin failed."
    return 1
  fi

  # Update the module graph with the selected orchestrion dependency while
  # keeping the version fixed to the same concrete tag used above.
  if ! (cd "$go_module_dir" && go get github.com/DataDog/orchestrion@$resolved_orchestrion_tag) >&2; then
    >&2 echo "Error: go get github.com/DataDog/orchestrion@$resolved_orchestrion_tag failed."
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
