#!/bin/bash

# This harness validates the Go installation decision matrix by running the
# install script against fake go/curl/orchestrion binaries. That keeps the
# tests deterministic while still exercising the full shell control flow.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/install_test_visibility.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dd-tv-go-matrix.XXXXXX")"

PASS_COUNT=0
FAIL_COUNT=0
LAST_EXIT_CODE=0
LAST_STDOUT=""
LAST_STDERR=""
CURRENT_CASE_DIR=""
CURRENT_WORKSPACE=""

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# Print a failure message and stop the current scenario.
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Assert that the script exited with the expected status code.
assert_exit_code() {
  local expected="$1"
  if [ "$LAST_EXIT_CODE" -ne "$expected" ]; then
    fail "expected exit code $expected, got $LAST_EXIT_CODE"
  fi
}

# Assert that a file contains the expected text.
assert_file_contains() {
  local file_path="$1"
  local expected_text="$2"
  if ! grep -Fq "$expected_text" "$file_path"; then
    echo "Expected to find '$expected_text' in $file_path" >&2
    echo "----- $file_path -----" >&2
    cat "$file_path" >&2
    fail "missing expected text"
  fi
}

# Assert that a file does not contain the given text.
assert_file_not_contains() {
  local file_path="$1"
  local unexpected_text="$2"
  if grep -Fq "$unexpected_text" "$file_path"; then
    echo "Did not expect to find '$unexpected_text' in $file_path" >&2
    echo "----- $file_path -----" >&2
    cat "$file_path" >&2
    fail "found unexpected text"
  fi
}

# Assert that a file exists.
assert_file_exists() {
  local file_path="$1"
  if [ ! -f "$file_path" ]; then
    fail "expected file to exist: $file_path"
  fi
}

# Assert that a file does not exist.
assert_file_missing() {
  local file_path="$1"
  if [ -e "$file_path" ]; then
    fail "expected file to be absent: $file_path"
  fi
}

# Assert that two files are byte-for-byte identical.
assert_files_equal() {
  local expected_file="$1"
  local actual_file="$2"
  if ! cmp -s "$expected_file" "$actual_file"; then
    echo "Files differ:" >&2
    echo "----- expected: $expected_file -----" >&2
    cat "$expected_file" >&2
    echo "----- actual: $actual_file -----" >&2
    cat "$actual_file" >&2
    fail "files differ"
  fi
}

# Write a simple go.mod file that includes a go directive.
write_go_mod() {
  local file_path="$1"
  local module_name="$2"
  local go_version="$3"
  cat > "$file_path" <<EOF
module $module_name

go $go_version
EOF
}

# Write a simple go.mod file without a go directive.
write_go_mod_without_go_directive() {
  local file_path="$1"
  local module_name="$2"
  cat > "$file_path" <<EOF
module $module_name
EOF
}

# Create the fake toolchain used by one matrix scenario.
create_fake_toolchain() {
  mkdir -p "$CURRENT_CASE_DIR/bin" "$CURRENT_CASE_DIR/logs"

  cat > "$CURRENT_CASE_DIR/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail

url="${@: -1}"

if [[ "$url" == *"/repos/datadog/orchestrion/releases/latest" ]]; then
  counter_file="$FAKE_LOG_DIR/latest_requests.count"
  count=0
  if [ -f "$counter_file" ]; then
    count="$(cat "$counter_file")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$counter_file"
  printf '{"tag_name":"%s"}\n' "${FAKE_LATEST_ORCHESTRION_TAG:-v1.8.0}"
  exit 0
fi

if [[ "$url" == *"raw.githubusercontent.com/DataDog/orchestrion/"*"/go.mod" ]]; then
  cat <<MOD
module github.com/DataDog/orchestrion

go ${FAKE_ORCHESTRION_GO_VERSION:-1.24.0}

require (
	github.com/DataDog/dd-trace-go/v2 ${FAKE_ORCHESTRION_DD_TRACE_VERSION:-v2.6.0}
)
MOD
  exit 0
fi

if [[ "$url" == *"raw.githubusercontent.com/DataDog/dd-trace-go/"*"/orchestrion/all/go.mod" ]]; then
  version="$(echo "$url" | sed -n 's#.*DataDog/dd-trace-go/\(v[0-9][^/]*\)/orchestrion/all/go.mod#\1#p')"
  case "$version" in
    v2.6.0) go_version="1.24.0" ;;
    v2.7.0) go_version="1.25.0" ;;
    v2.8.0) go_version="1.26.0" ;;
    *) go_version="${FAKE_DEFAULT_DD_TRACE_GO_VERSION:-1.24.0}" ;;
  esac
  cat <<MOD
module github.com/DataDog/dd-trace-go/orchestrion/all/v2

go $go_version
MOD
  exit 0
fi

echo "Unsupported fake curl request: $url" >&2
exit 1
EOF
  chmod +x "$CURRENT_CASE_DIR/bin/curl"

  cat > "$CURRENT_CASE_DIR/bin/go" <<'EOF'
#!/bin/bash
set -euo pipefail

append_or_replace_requirement() {
  local go_mod_path="$1"
  local module_path="$2"
  local module_version="$3"
  local temp_path="${go_mod_path}.tmp"

  awk -v module_path="$module_path" '
    ($1 == module_path) || ($1 == "require" && $2 == module_path) { next }
    { print }
  ' "$go_mod_path" > "$temp_path"
  mv "$temp_path" "$go_mod_path"
  printf 'require %s %s\n' "$module_path" "$module_version" >> "$go_mod_path"
}

log_file="$FAKE_LOG_DIR/go.log"
command_name="${1:-}"
if [ $# -gt 0 ]; then
  shift
fi

case "$command_name" in
  version)
    printf 'go version go%s darwin/arm64\n' "${FAKE_GO_VERSION:-1.26.1}"
    ;;
  list)
    if [ "${1:-}" = "-m" ] && [ "${2:-}" = "-versions" ] && [ "${3:-}" = "github.com/DataDog/dd-trace-go/v2" ]; then
      if [ "${FAKE_FAIL_STABLE_LIST:-0}" = "1" ]; then
        exit 1
      fi
      printf 'github.com/DataDog/dd-trace-go/v2 %s\n' "${FAKE_DD_TRACE_GO_VERSIONS:-v2.6.0 v2.7.0 v2.8.0}"
    else
      echo "Unsupported fake go list invocation: go list $*" >&2
      exit 98
    fi
    ;;
  install)
    printf 'install %s\n' "$*" >> "$log_file"
    if [ "${FAKE_FAIL_GO_INSTALL:-0}" = "1" ]; then
      exit 1
    fi
    ;;
  mod)
    if [ "${1:-}" = "edit" ]; then
      printf 'mod %s\n' "$*" >> "$log_file"
      requirement=""
      for argument in "$@"; do
        case "$argument" in
          -require=*)
            requirement="${argument#-require=}"
            ;;
        esac
      done
      if [ -z "$requirement" ]; then
        echo "Unsupported fake go mod edit invocation: go mod $*" >&2
        exit 97
      fi
      append_or_replace_requirement "$(pwd)/go.mod" "${requirement%@*}" "${requirement##*@}"
    else
      echo "Unsupported fake go mod invocation: go mod $*" >&2
      exit 96
    fi
    ;;
  get)
    printf 'get %s\n' "$*" >> "$log_file"
    append_or_replace_requirement "$(pwd)/go.mod" "${1%@*}" "${1##*@}"
    ;;
  *)
    echo "Unsupported fake go command: go $command_name $*" >&2
    exit 95
    ;;
esac
EOF
  chmod +x "$CURRENT_CASE_DIR/bin/go"

  cat > "$CURRENT_CASE_DIR/bin/orchestrion" <<'EOF'
#!/bin/bash
set -euo pipefail

append_or_replace_requirement() {
  local go_mod_path="$1"
  local module_path="$2"
  local module_version="$3"
  local temp_path="${go_mod_path}.tmp"

  awk -v module_path="$module_path" '
    ($1 == module_path) || ($1 == "require" && $2 == module_path) { next }
    { print }
  ' "$go_mod_path" > "$temp_path"
  mv "$temp_path" "$go_mod_path"
  printf 'require %s %s\n' "$module_path" "$module_version" >> "$go_mod_path"
}

command_name="${1:-}"
case "$command_name" in
  pin)
    if [ "${FAKE_FAIL_PIN:-0}" = "1" ]; then
      exit 1
    fi
    tracer_version="$(awk '
      ($1 == "github.com/DataDog/dd-trace-go/v2") { version = $2 }
      ($1 == "require" && $2 == "github.com/DataDog/dd-trace-go/v2") { version = $3 }
      END { print version }
    ' go.mod)"
    if [ -z "$tracer_version" ]; then
      tracer_version="${FAKE_ORCHESTRION_DD_TRACE_VERSION:-v2.6.0}"
    fi
    append_or_replace_requirement "$(pwd)/go.mod" "github.com/DataDog/dd-trace-go/orchestrion/all/v2" "$tracer_version"
    cat > orchestrion.tool.go <<TOOL
// Fake orchestrion output for tests.
package tools
TOOL
    ;;
  version)
    printf 'orchestrion %s\n' "${FAKE_ORCHESTRION_VERSION:-v1.8.0}"
    ;;
  *)
    echo "Unsupported fake orchestrion command: orchestrion $*" >&2
    exit 94
    ;;
esac
EOF
  chmod +x "$CURRENT_CASE_DIR/bin/orchestrion"
}

# Create a clean per-scenario workspace and fake toolchain.
prepare_case() {
  local case_name="$1"
  CURRENT_CASE_DIR="$TEST_ROOT/$case_name"
  CURRENT_WORKSPACE="$CURRENT_CASE_DIR/workspace"
  mkdir -p "$CURRENT_WORKSPACE"
  create_fake_toolchain
}

# Run the install script inside the current scenario workspace.
run_install_script() {
  LAST_STDOUT="$CURRENT_CASE_DIR/stdout.txt"
  LAST_STDERR="$CURRENT_CASE_DIR/stderr.txt"

  set +e
  (
    cd "$CURRENT_WORKSPACE" &&
    env \
      PATH="$CURRENT_CASE_DIR/bin:$PATH" \
      FAKE_LOG_DIR="$CURRENT_CASE_DIR/logs" \
      "$@" \
      bash "$SCRIPT_UNDER_TEST" > "$LAST_STDOUT" 2> "$LAST_STDERR"
  )
  LAST_EXIT_CODE=$?
  set -e
}

# Execute one scenario in isolation and keep the matrix running on failures.
run_case() {
  local case_name="$1"
  shift

  if ( "$@" ); then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS %s\n' "$case_name"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL %s\n' "$case_name"
  fi
}

# Validate the root-module happy path for a Go 1.24 project.
scenario_root_module_go_124() {
  prepare_case "root_module_go_124"
  write_go_mod "$CURRENT_WORKSPACE/go.mod" "example.com/root" "1.24"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 0
  assert_file_contains "$LAST_STDOUT" "GOFLAGS="
  assert_file_contains "$LAST_STDOUT" "DD_TRACER_VERSION_GO=v1.8.0"
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/dd-trace-go/orchestrion/all/v2 v2.6.0"
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/dd-trace-go/v2 v2.6.0"
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/orchestrion v1.8.0"
  assert_file_exists "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

# Validate the root-module upgrade path for a Go 1.25 project.
scenario_root_module_go_125() {
  prepare_case "root_module_go_125"
  write_go_mod "$CURRENT_WORKSPACE/go.mod" "example.com/root" "1.25"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 0
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/dd-trace-go/orchestrion/all/v2 v2.7.0"
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/dd-trace-go/v2 v2.7.0"
  assert_file_exists "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

# Validate that too-old projects are skipped without mutating go.mod.
scenario_root_module_go_122_skips() {
  prepare_case "root_module_go_122_skips"
  write_go_mod "$CURRENT_WORKSPACE/go.mod" "example.com/root" "1.22"
  cp "$CURRENT_WORKSPACE/go.mod" "$CURRENT_CASE_DIR/initial.go.mod"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Skipping orchestrion installation."
  assert_file_not_contains "$LAST_STDOUT" "GOFLAGS="
  assert_files_equal "$CURRENT_CASE_DIR/initial.go.mod" "$CURRENT_WORKSPACE/go.mod"
  assert_file_missing "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

# Validate the runner lower-bound check from orchestrion's own go.mod.
scenario_runner_below_orchestrion_minimum() {
  prepare_case "runner_below_orchestrion_minimum"
  write_go_mod "$CURRENT_WORKSPACE/go.mod" "example.com/root" "1.24"
  cp "$CURRENT_WORKSPACE/go.mod" "$CURRENT_CASE_DIR/initial.go.mod"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1 \
    FAKE_ORCHESTRION_GO_VERSION=1.27.0

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "does not meet the required version"
  assert_file_not_contains "$LAST_STDOUT" "GOFLAGS="
  assert_files_equal "$CURRENT_CASE_DIR/initial.go.mod" "$CURRENT_WORKSPACE/go.mod"
  assert_file_missing "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

# Validate the runner lower-bound check for the shipped tracer bundle.
scenario_runner_below_shipped_tracer_minimum() {
  prepare_case "runner_below_shipped_tracer_minimum"
  write_go_mod "$CURRENT_WORKSPACE/go.mod" "example.com/root" "1.25"
  cp "$CURRENT_WORKSPACE/go.mod" "$CURRENT_CASE_DIR/initial.go.mod"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.24.0 \
    FAKE_ORCHESTRION_GO_VERSION=1.24.0 \
    FAKE_ORCHESTRION_DD_TRACE_VERSION=v2.7.0

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "lower than the minimum Go version required by dd-trace-go v2.7.0"
  assert_file_not_contains "$LAST_STDOUT" "GOFLAGS="
  assert_files_equal "$CURRENT_CASE_DIR/initial.go.mod" "$CURRENT_WORKSPACE/go.mod"
  assert_file_missing "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

# Validate nested-module auto-detection for a Go 1.24 project.
scenario_single_nested_module_go_124() {
  prepare_case "single_nested_module_go_124"
  mkdir -p "$CURRENT_WORKSPACE/app"
  write_go_mod "$CURRENT_WORKSPACE/app/go.mod" "example.com/app" "1.24"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 0
  assert_file_contains "$CURRENT_WORKSPACE/app/go.mod" "github.com/DataDog/dd-trace-go/orchestrion/all/v2 v2.6.0"
  assert_file_contains "$CURRENT_WORKSPACE/app/go.mod" "github.com/DataDog/dd-trace-go/v2 v2.6.0"
  assert_file_exists "$CURRENT_WORKSPACE/app/orchestrion.tool.go"
  assert_file_missing "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

# Validate nested-module auto-detection for a Go 1.25 project.
scenario_single_nested_module_go_125() {
  prepare_case "single_nested_module_go_125"
  mkdir -p "$CURRENT_WORKSPACE/app"
  write_go_mod "$CURRENT_WORKSPACE/app/go.mod" "example.com/app" "1.25"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 0
  assert_file_contains "$CURRENT_WORKSPACE/app/go.mod" "github.com/DataDog/dd-trace-go/orchestrion/all/v2 v2.7.0"
  assert_file_contains "$CURRENT_WORKSPACE/app/go.mod" "github.com/DataDog/dd-trace-go/v2 v2.7.0"
  assert_file_exists "$CURRENT_WORKSPACE/app/orchestrion.tool.go"
  assert_file_missing "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

# Validate the clean skip path for multiple nested modules without an override.
scenario_multiple_modules_without_override() {
  prepare_case "multiple_modules_without_override"
  mkdir -p "$CURRENT_WORKSPACE/api" "$CURRENT_WORKSPACE/worker"
  write_go_mod "$CURRENT_WORKSPACE/api/go.mod" "example.com/api" "1.24"
  write_go_mod "$CURRENT_WORKSPACE/worker/go.mod" "example.com/worker" "1.24"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Set DD_CIVISIBILITY_GO_MODULE_DIR"
  assert_file_missing "$CURRENT_WORKSPACE/api/orchestrion.tool.go"
  assert_file_missing "$CURRENT_WORKSPACE/worker/orchestrion.tool.go"
}

# Validate explicit module selection in a multi-module repository.
scenario_multiple_modules_with_override() {
  prepare_case "multiple_modules_with_override"
  mkdir -p "$CURRENT_WORKSPACE/api" "$CURRENT_WORKSPACE/worker"
  write_go_mod "$CURRENT_WORKSPACE/api/go.mod" "example.com/api" "1.24"
  write_go_mod "$CURRENT_WORKSPACE/worker/go.mod" "example.com/worker" "1.25"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    DD_CIVISIBILITY_GO_MODULE_DIR=worker \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 0
  assert_file_missing "$CURRENT_WORKSPACE/api/orchestrion.tool.go"
  assert_file_exists "$CURRENT_WORKSPACE/worker/orchestrion.tool.go"
  assert_file_contains "$CURRENT_WORKSPACE/worker/go.mod" "github.com/DataDog/dd-trace-go/orchestrion/all/v2 v2.7.0"
  assert_file_not_contains "$CURRENT_WORKSPACE/api/go.mod" "github.com/DataDog/orchestrion"
}

# Validate the explicit missing-directory failure path.
scenario_override_missing_directory() {
  prepare_case "override_missing_directory"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    DD_CIVISIBILITY_GO_MODULE_DIR=missing \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "DD_CIVISIBILITY_GO_MODULE_DIR points to a directory that does not exist"
  assert_file_not_contains "$LAST_STDOUT" "GOFLAGS="
}

# Validate the explicit "directory exists but has no go.mod" failure path.
scenario_override_without_go_mod() {
  prepare_case "override_without_go_mod"
  mkdir -p "$CURRENT_WORKSPACE/empty"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    DD_CIVISIBILITY_GO_MODULE_DIR=empty \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "DD_CIVISIBILITY_GO_MODULE_DIR does not contain a go.mod file"
  assert_file_not_contains "$LAST_STDOUT" "GOFLAGS="
}

# Validate the clean skip path when no Go module exists anywhere.
scenario_no_go_mod_anywhere() {
  prepare_case "no_go_mod_anywhere"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Could not find a go.mod file"
  assert_file_not_contains "$LAST_STDOUT" "GOFLAGS="
  assert_file_missing "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

# Validate the fallback path for projects without a go directive.
scenario_missing_go_directive_falls_back() {
  prepare_case "missing_go_directive_falls_back"
  write_go_mod_without_go_directive "$CURRENT_WORKSPACE/go.mod" "example.com/root"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Could not read the project Go version"
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/dd-trace-go/orchestrion/all/v2 v2.6.0"
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/dd-trace-go/v2 v2.6.0"
  assert_file_exists "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

# Validate the fallback path when the stable tracer list cannot be retrieved.
scenario_missing_stable_tracer_list_falls_back() {
  prepare_case "missing_stable_tracer_list_falls_back"
  write_go_mod "$CURRENT_WORKSPACE/go.mod" "example.com/root" "1.25"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1 \
    FAKE_FAIL_STABLE_LIST=1

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Could not retrieve the list of stable dd-trace-go versions."
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/dd-trace-go/orchestrion/all/v2 v2.6.0"
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/dd-trace-go/v2 v2.6.0"
}

# Validate that "latest" is resolved once and reused consistently.
scenario_latest_resolved_once() {
  prepare_case "latest_resolved_once"
  write_go_mod "$CURRENT_WORKSPACE/go.mod" "example.com/root" "1.24"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=latest \
    FAKE_GO_VERSION=1.26.1 \
    FAKE_LATEST_ORCHESTRION_TAG=v1.8.0

  assert_exit_code 0
  assert_file_contains "$CURRENT_CASE_DIR/logs/latest_requests.count" "1"
  assert_file_contains "$CURRENT_CASE_DIR/logs/go.log" "install github.com/DataDog/orchestrion@v1.8.0"
  assert_file_contains "$CURRENT_CASE_DIR/logs/go.log" "get github.com/DataDog/orchestrion@v1.8.0"
  assert_file_contains "$CURRENT_WORKSPACE/go.mod" "github.com/DataDog/orchestrion v1.8.0"
}

# Validate that a failed orchestrion install does not dirty go.mod.
scenario_failed_go_install_keeps_go_mod_clean() {
  prepare_case "failed_go_install_keeps_go_mod_clean"
  write_go_mod "$CURRENT_WORKSPACE/go.mod" "example.com/root" "1.24"
  cp "$CURRENT_WORKSPACE/go.mod" "$CURRENT_CASE_DIR/initial.go.mod"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
    DD_SET_TRACER_VERSION_GO=v1.8.0 \
    FAKE_GO_VERSION=1.26.1 \
    FAKE_FAIL_GO_INSTALL=1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: Could not install orchestrion for Go."
  assert_files_equal "$CURRENT_CASE_DIR/initial.go.mod" "$CURRENT_WORKSPACE/go.mod"
  assert_file_not_contains "$CURRENT_CASE_DIR/logs/go.log" "mod edit"
  assert_file_missing "$CURRENT_WORKSPACE/orchestrion.tool.go"
}

main() {
  run_case "root_module_go_124" scenario_root_module_go_124
  run_case "root_module_go_125" scenario_root_module_go_125
  run_case "root_module_go_122_skips" scenario_root_module_go_122_skips
  run_case "runner_below_orchestrion_minimum" scenario_runner_below_orchestrion_minimum
  run_case "runner_below_shipped_tracer_minimum" scenario_runner_below_shipped_tracer_minimum
  run_case "single_nested_module_go_124" scenario_single_nested_module_go_124
  run_case "single_nested_module_go_125" scenario_single_nested_module_go_125
  run_case "multiple_modules_without_override" scenario_multiple_modules_without_override
  run_case "multiple_modules_with_override" scenario_multiple_modules_with_override
  run_case "override_missing_directory" scenario_override_missing_directory
  run_case "override_without_go_mod" scenario_override_without_go_mod
  run_case "no_go_mod_anywhere" scenario_no_go_mod_anywhere
  run_case "missing_go_directive_falls_back" scenario_missing_go_directive_falls_back
  run_case "missing_stable_tracer_list_falls_back" scenario_missing_stable_tracer_list_falls_back
  run_case "latest_resolved_once" scenario_latest_resolved_once
  run_case "failed_go_install_keeps_go_mod_clean" scenario_failed_go_install_keeps_go_mod_clean

  printf '\nGo matrix: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
