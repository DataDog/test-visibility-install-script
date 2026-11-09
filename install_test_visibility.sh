# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/)
# Copyright 2024-present Datadog, Inc.

# This script installs Datadog tracing libraries for the specified languages
# and prints to standard output the environment variables that need to be set for enabling Test Visibility.

# The variables are printed in the following format: variableName=variableValue

set -e

ARTIFACTS_FOLDER="${DD_TRACER_FOLDER:-$(pwd)/.datadog}"
if ! mkdir -p "$ARTIFACTS_FOLDER"; then
  >&2 echo "Error: Cannot create folder: $ARTIFACTS_FOLDER"
  return 1
fi

DEFAULT_JAVA_TRACER_REPOSITORY_URL="https://repo1.maven.org/maven2/com/datadoghq/dd-java-agent"

# Go tests report through ddtest instrument, which ddtest has carried since
# v1.14.0 and which needs a Go 1.25 or newer toolchain.
DDTEST_RELEASES_URL="https://github.com/DataDog/ddtest/releases"
DDTEST_MINIMUM_VERSION="v1.14.0"
DDTEST_MINIMUM_GO_VERSION="1.25.0"

extract_major_version() {
  echo "$1" | cut -d '.' -f 1
}

extract_minor_version() {
  echo "$1" | cut -d '.' -f 2
}

install_java_tracer() {
  if ! validate_java_auth_header_configuration; then
    return 1
  fi

  local repository_base_url
  repository_base_url="$(get_java_tracer_repository_base_url)"

  if [ -z "$DD_SET_TRACER_VERSION_JAVA" ]; then
      DD_SET_TRACER_VERSION_JAVA=$(get_latest_java_tracer_version "$repository_base_url")
  fi

  local filepath_tracer
  filepath_tracer="$ARTIFACTS_FOLDER/dd-java-agent.jar"
  local filepath_checksum
  filepath_checksum="$ARTIFACTS_FOLDER/dd-java-agent.jar.sha256"

  download_file "$repository_base_url/$DD_SET_TRACER_VERSION_JAVA/dd-java-agent-$DD_SET_TRACER_VERSION_JAVA.jar" "$filepath_tracer" "${DD_SET_AUTH_HEADER_JAVA:-}"
  download_file "$repository_base_url/$DD_SET_TRACER_VERSION_JAVA/dd-java-agent-$DD_SET_TRACER_VERSION_JAVA.jar.sha256" "$filepath_checksum" "${DD_SET_AUTH_HEADER_JAVA:-}"

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

validate_java_auth_header_configuration() {
  if [ -n "${DD_SET_AUTH_HEADER_JAVA:-}" ] && [ -z "${DD_SET_TRACER_REPOSITORY_URL_JAVA:-}" ]; then
    >&2 echo "Error: DD_SET_AUTH_HEADER_JAVA requires DD_SET_TRACER_REPOSITORY_URL_JAVA to be set to a custom repository URL."
    return 1
  fi

  if [ -n "${DD_SET_AUTH_HEADER_JAVA:-}" ]; then
    local repository_base_url
    repository_base_url="$(normalize_java_tracer_repository_base_url "$DD_SET_TRACER_REPOSITORY_URL_JAVA")"
    if [ "$repository_base_url" = "$DEFAULT_JAVA_TRACER_REPOSITORY_URL" ]; then
      >&2 echo "Error: DD_SET_AUTH_HEADER_JAVA cannot be used with the default Maven Central repository. Set DD_SET_TRACER_REPOSITORY_URL_JAVA to a custom repository URL."
      return 1
    fi
  fi
}

# Succeed when the SHA-256 digest of file $2 is $1. The digest is computed and
# compared here rather than with sha256sum -c, whose options differ: BusyBox's,
# on Alpine images, rejects --quiet.
verify_checksum() {
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum < "$2" | cut -d ' ' -f 1)
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 < "$2" | cut -d ' ' -f 1)
  else
    >&2 echo "Error: Neither sha256sum nor shasum is installed."
    return 1
  fi
  local expected
  expected=$(echo "$1" | awk '{ print tolower($1) }')
  if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
    >&2 echo "$2: computed checksum does not match $expected"
    return 1
  fi
}

get_java_tracer_repository_base_url() {
  local base_url="${DD_SET_TRACER_REPOSITORY_URL_JAVA:-$DEFAULT_JAVA_TRACER_REPOSITORY_URL}"
  normalize_java_tracer_repository_base_url "$base_url"
}

normalize_java_tracer_repository_base_url() {
  local base_url="$1"
  # Trim trailing slashes so callers can append "/<version>/..." uniformly
  # regardless of whether the override was provided with or without one.
  while [ "${base_url%/}" != "$base_url" ]; do
    base_url="${base_url%/}"
  done
  echo "$base_url"
}

get_latest_java_tracer_version() {
  local repository_base_url="$1"

  local filepath_metadata
  filepath_metadata="$ARTIFACTS_FOLDER/maven-metadata.xml"
  local filepath_checksum
  filepath_checksum="$ARTIFACTS_FOLDER/maven-metadata.xml.sha256"

  download_file "$repository_base_url/maven-metadata.xml" "$filepath_metadata" "${DD_SET_AUTH_HEADER_JAVA:-}"
  download_file "$repository_base_url/maven-metadata.xml.sha256" "$filepath_checksum" "${DD_SET_AUTH_HEADER_JAVA:-}"

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
  local auth_header="${3:-}"
  local disable_redirects="${DD_SET_AUTH_HEADER_JAVA_DISABLE_REDIRECTS:-}"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$auth_header" ]; then
      if [ -n "$disable_redirects" ]; then
        curl -fLo "$filepath" --max-redirs 0 -H "$auth_header" "$url"
      else
        curl -fLo "$filepath" -H "$auth_header" "$url"
      fi
    else
      curl -fLo "$filepath" "$url"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "$auth_header" ]; then
      if [ -n "$disable_redirects" ]; then
        wget --max-redirect=0 -O "$filepath" --header="$auth_header" "$url"
      else
        wget -O "$filepath" --header="$auth_header" "$url"
      fi
    else
      wget -O "$filepath" "$url"
    fi
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

  # npm puts global packages in lib/node_modules under the prefix, but in
  # node_modules on Windows, where it also prints the native path that Node
  # needs instead of Git Bash's POSIX one.
  local global_node_modules
  if ! global_node_modules=$(npm root -g); then
    >&2 echo "Error: Could not find the folder of global npm packages"
    return 1
  fi

  # Github Actions prohibit setting NODE_OPTIONS
  local dd_trace_ci_init_path="$global_node_modules/dd-trace/ci/init"
  local dd_trace_register_path="$global_node_modules/dd-trace/register.js"
  if ! is_github_actions; then
    echo "NODE_OPTIONS=$NODE_OPTIONS -r $dd_trace_ci_init_path"
  else
    echo "DD_TRACE_PACKAGE=$dd_trace_ci_init_path"
  fi
  # Node's --import takes a URL or a specifier, and reads a Windows path such
  # as D:\a\register.js as a URL with the scheme d:, so Windows gets a file URL.
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "winnt" ]]; then
    if ! dd_trace_register_path=$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$dd_trace_register_path"); then
      >&2 echo "Error: Could not build the file URL of $dd_trace_register_path"
      return 1
    fi
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

  if ! pip install -U ddtrace${DD_SET_TRACER_VERSION_PYTHON:+==$DD_SET_TRACER_VERSION_PYTHON} >&2; then
    >&2 echo "Error: Could not install ddtrace for Python"
    return 1
  fi

  local dd_trace_path
  dd_trace_path=$(pip show ddtrace | grep Location | awk '{print $2}')
  if ! [ -d $dd_trace_path ]; then
    >&2 echo "Error: Could not determine ddtrace package location (tried $dd_trace_path)"
    return 1
  fi

  # Python on Windows separates PYTHONPATH entries with ';', and pip prints
  # the native path there.
  local python_path_separator=":"
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "winnt" ]]; then
    python_path_separator=";"
  fi
  echo "PYTHONPATH=$dd_trace_path$python_path_separator$PYTHONPATH"
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
# Print the name of ddtest's release executable for this host, or fail when
# ddtest publishes none for it. On Windows the script runs in Git Bash, MSYS2 or
# Cygwin.
ddtest_release_asset() {
  local os
  local suffix=""
  local arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os=windows; suffix=".exe" ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  echo "ddtest-$os-$arch$suffix"
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

install_go_tracer() {
  # Check if go is installed
  if ! command -v go >/dev/null 2>&1; then
    >&2 echo "Error: go is not installed."
    return 1
  fi

  # ddtest instrument builds with the runner's toolchain; the project's go.mod
  # can still declare an older Go version. A go that cannot report its version,
  # such as a toolchain that GOTOOLCHAIN fails to download, is an error, not a
  # Go too old to instrument.
  local go_version_output
  if ! go_version_output=$(go version); then
    >&2 echo "Error: go version failed."
    return 1
  fi
  local installed_go_version
  installed_go_version=$(echo "$go_version_output" | grep -o -E 'go[0-9]+(\.[0-9]+)*((rc|beta)[0-9]*)?' | head -n 1 | sed 's/^go//')
  if [ -z "$installed_go_version" ]; then
    >&2 echo "Error: Could not read the Go version from: $go_version_output"
    return 1
  fi
  # As Go orders versions, and ddtest with them, a prerelease such as go1.25rc1
  # and a development build such as "devel go1.25-abc" come before go1.25.0.
  local installed_go_release="${installed_go_version%%[a-z]*}"
  if ! version_ge "$installed_go_release" "$DDTEST_MINIMUM_GO_VERSION" ||
     { version_ge "$DDTEST_MINIMUM_GO_VERSION" "$installed_go_release" && [ "$installed_go_version" != "$DDTEST_MINIMUM_GO_VERSION" ]; }; then
    >&2 echo "Warning: The installed Go version ($installed_go_version) is lower than the Go $DDTEST_MINIMUM_GO_VERSION that ddtest instrument needs."
    >&2 echo "Skipping Go instrumentation."
    return 0
  fi

  local asset
  if ! asset=$(ddtest_release_asset); then
    >&2 echo "Warning: ddtest has no release executable for $(uname -s) $(uname -m)."
    >&2 echo "Skipping Go instrumentation."
    return 0
  fi

  # DD_SET_TRACER_VERSION_GO selects a ddtest release; it selected an
  # Orchestrion release, or commit, before ddtest replaced Orchestrion. A value
  # that names no ddtest release with ddtest instrument, such as an earlier
  # Orchestrion pin, cannot be honored: the latest ddtest is installed instead,
  # with a warning, so the job keeps Go instrumented.
  local unusable_version_warning="Warning: DD_SET_TRACER_VERSION_GO=$DD_SET_TRACER_VERSION_GO is not a ddtest release from $DDTEST_MINIMUM_VERSION on; ddtest replaced Orchestrion for Go. Installing the latest ddtest release."
  local ddtest_version="${DD_SET_TRACER_VERSION_GO:-latest}"
  if [ "$ddtest_version" != "latest" ]; then
    if [[ "$ddtest_version" =~ ^[0-9] ]]; then
      ddtest_version="v$ddtest_version"
    fi
    if ! [[ "$ddtest_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! version_ge "$ddtest_version" "$DDTEST_MINIMUM_VERSION"; then
      >&2 echo "$unusable_version_warning"
      ddtest_version="latest"
    fi
  fi

  local filepath_ddtest
  filepath_ddtest="$ARTIFACTS_FOLDER/ddtest"
  if [[ "$asset" == *.exe ]]; then
    filepath_ddtest="$filepath_ddtest.exe"
  fi
  local filepath_checksums
  filepath_checksums="$ARTIFACTS_FOLDER/ddtest.SHA256SUMS"

  # download_file runs curl when it can, else wget. Each reports that the
  # server answered with an error, such as 404, with its own exit status:
  # 22 from curl -f, 8 from wget. For curl, 8 is a reply it could not parse.
  local server_error_status=22
  if ! command -v curl >/dev/null 2>&1; then
    server_error_status=8
  fi
  local download_url
  local download_status
  while true; do
    if [ "$ddtest_version" = "latest" ]; then
      download_url="$DDTEST_RELEASES_URL/latest/download"
    else
      download_url="$DDTEST_RELEASES_URL/download/$ddtest_version"
    fi
    download_status=0
    download_file "$download_url/SHA256SUMS" "$filepath_checksums" >&2 || download_status=$?
    # The server answered with an error for a pinned release: the release does
    # not exist, as with a version number that ddtest never published, so the
    # latest ddtest is installed instead. Network failures stay errors.
    if [ "$ddtest_version" != "latest" ] && [ "$download_status" -eq "$server_error_status" ]; then
      >&2 echo "$unusable_version_warning"
      ddtest_version="latest"
      continue
    fi
    break
  done
  if [ $download_status -ne 0 ]; then
    rm -f "$filepath_checksums"
    >&2 echo "Error: Could not download $download_url/SHA256SUMS."
    return 1
  fi
  local checksum
  checksum=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$filepath_checksums")
  rm -f "$filepath_checksums"
  if [ -z "$checksum" ]; then
    >&2 echo "Error: The ddtest release at $download_url has no $asset."
    return 1
  fi

  # The go shims of an earlier installation link to filepath_ddtest, so the
  # new executable is downloaded and checked beside it and then renamed over
  # it: a failed download or a checksum mismatch keeps the installed one.
  local filepath_download
  filepath_download="$filepath_ddtest.download.$$"
  if ! download_file "$download_url/$asset" "$filepath_download" >&2; then
    rm -f "$filepath_download"
    >&2 echo "Error: Could not download $download_url/$asset."
    return 1
  fi
  if ! verify_checksum "$checksum" "$filepath_download" >&2; then
    rm -f "$filepath_download"
    >&2 echo "Error: $asset does not match the checksum in the ddtest release."
    return 1
  fi
  if ! { chmod +x "$filepath_download" && mv -f "$filepath_download" "$filepath_ddtest"; }; then
    rm -f "$filepath_download"
    >&2 echo "Error: Could not install ddtest in $filepath_ddtest."
    return 1
  fi

  # With --go-shim, ddtest runs a command with a go of its own first on PATH:
  # that go runs go test through ddtest instrument and every other go command
  # unchanged. Without --go-shim, ddtest takes its go shims off PATH, so the
  # second command finds the toolchain's go. If ddtest cannot set the shim up,
  # it warns and runs the command without it, and both commands print the same
  # go.
  local go_shim
  local toolchain_go
  if ! go_shim=$("$filepath_ddtest" instrument --go-shim sh -c 'command -v go') ||
     ! toolchain_go=$("$filepath_ddtest" instrument sh -c 'command -v go') ||
     [ -z "$go_shim" ] || [ "$go_shim" = "$toolchain_go" ]; then
    >&2 echo "Error: ddtest could not set up its go command for Go instrumentation."
    return 1
  fi

  # Putting ddtest's go first on PATH makes the go test that a job runs, also
  # from make or a script, report to Test Optimization, without changing the
  # project's go.mod or the job's commands.
  local go_shim_dir
  go_shim_dir=$(dirname "$go_shim")
  # The printed PATH serves a shell that exports the output. In GitHub Actions,
  # the job's next steps get the directories that GITHUB_PATH lists, such as
  # setup-go's, before the PATH that GITHUB_ENV sets, so the directory goes to
  # GITHUB_PATH too, last and so first on PATH. On Windows, Git Bash's PATH has
  # POSIX paths, which the next steps cannot use through GITHUB_ENV, so there
  # the script prints no PATH and only the next steps get the directory.
  if [ -n "${GITHUB_PATH:-}" ]; then
    local github_path_entry="$go_shim_dir"
    if [[ "$asset" == *.exe ]]; then
      github_path_entry=$(cygpath -w "$go_shim_dir")
    fi
    echo "$github_path_entry" >> "$GITHUB_PATH"
    >&2 echo "Added ddtest's go command to PATH for the next steps: $github_path_entry"
  fi
  if [ -z "${GITHUB_PATH:-}" ] || [[ "$asset" != *.exe ]]; then
    echo "PATH=$go_shim_dir:$PATH"
  fi
  echo "DD_TRACER_VERSION_GO=$("$filepath_ddtest" --version)"
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
