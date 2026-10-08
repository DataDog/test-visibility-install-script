#!/bin/bash

# This harness validates the Python installation path by running the install
# script against fake python/pip binaries. That keeps the tests deterministic
# while still exercising the full shell control flow. In particular, it guards
# against regressions such as force-installing the `coverage` package, which is
# no longer needed by ddtrace.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/install_test_visibility.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dd-tv-python-matrix.XXXXXX")"

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

# Assert that the `coverage` package is never installed or referenced.
assert_no_coverage() {
  assert_file_not_contains "$CURRENT_CASE_DIR/logs/pip.log" "coverage"
  assert_file_not_contains "$LAST_STDOUT" "coverage"
  assert_file_not_contains "$LAST_STDERR" "coverage"
}

# Create the fake toolchain used by one matrix scenario.
create_fake_toolchain() {
  mkdir -p "$CURRENT_CASE_DIR/bin" "$CURRENT_CASE_DIR/logs"

  cat > "$CURRENT_CASE_DIR/bin/python" <<'EOF'
#!/bin/bash
set -euo pipefail

command_name="${1:-}"
if [ $# -gt 0 ]; then
  shift
fi

case "$command_name" in
  -m)
    if [ "${1:-}" = "venv" ]; then
      venv_dir="${2:-.dd_civis_env}"
      mkdir -p "$venv_dir/bin"
      cat > "$venv_dir/bin/activate" <<ACTIVATE
# Fake venv activate script for tests.
deactivate() {
  unset VIRTUAL_ENV
}
export VIRTUAL_ENV="$PWD/$venv_dir"
ACTIVATE
      exit 0
    fi
    echo "Unsupported fake python invocation: python -m $*" >&2
    exit 91
    ;;
  *)
    echo "Unsupported fake python command: python $command_name $*" >&2
    exit 90
    ;;
esac
EOF
  chmod +x "$CURRENT_CASE_DIR/bin/python"

  cat > "$CURRENT_CASE_DIR/bin/bash" <<'EOF'
#!/bin/bash
# Delegate to the real bash so scenarios running with a fully restricted PATH
# can still invoke the install script itself.
exec /bin/bash "$@"
EOF
  chmod +x "$CURRENT_CASE_DIR/bin/bash"

  cat > "$CURRENT_CASE_DIR/bin/mkdir" <<'EOF'
#!/bin/bash
# Delegate to the real mkdir so scenarios running with a fully restricted
# PATH (only this bin directory) still let the install script create folders.
exec /bin/mkdir "$@"
EOF
  chmod +x "$CURRENT_CASE_DIR/bin/mkdir"

  cat > "$CURRENT_CASE_DIR/bin/pip" <<'EOF'
#!/bin/bash
set -euo pipefail

log_file="$FAKE_LOG_DIR/pip.log"
command_name="${1:-}"
if [ $# -gt 0 ]; then
  shift
fi

case "$command_name" in
  install)
    printf 'install %s\n' "$*" >> "$log_file"
    if [ "${FAKE_FAIL_PIP_INSTALL:-0}" = "1" ]; then
      exit 1
    fi
    mkdir -p "${FAKE_SITE_PACKAGES:?FAKE_SITE_PACKAGES must be set}"
    ;;
  show)
    if [ "${1:-}" != "ddtrace" ]; then
      echo "Unsupported fake pip show invocation: pip show $*" >&2
      exit 93
    fi
    printf 'Name: ddtrace\n'
    printf 'Version: %s\n' "${FAKE_DDTRACE_VERSION:-3.9.2}"
    printf 'Location: %s\n' "${FAKE_PIP_SHOW_LOCATION:-$FAKE_SITE_PACKAGES}"
    ;;
  *)
    echo "Unsupported fake pip command: pip $command_name $*" >&2
    exit 92
    ;;
esac
EOF
  chmod +x "$CURRENT_CASE_DIR/bin/pip"
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

  # Keep the PATH fully controlled by the harness when a scenario needs to
  # simulate a missing tool (e.g. no pip anywhere on the system): the PATH
  # contains ONLY the fake toolchain bin directory, so no system tool (pip
  # included, e.g. /usr/bin/pip on GitHub ubuntu runners) can leak in. The
  # fake toolchain provides every command the script needs on that path
  # (python and a delegating mkdir). The flag is read from the scenario
  # arguments because those are plain strings, not environment variables,
  # at this point.
  local effective_path="$CURRENT_CASE_DIR/bin:$PATH"
  local arg
  for arg in "$@"; do
    if [ "$arg" = "FAKE_RESTRICTED_PATH=1" ]; then
      effective_path="$CURRENT_CASE_DIR/bin"
    fi
  done

  set +e
  (
    cd "$CURRENT_WORKSPACE" &&
    env \
      PATH="$effective_path" \
      PYTHONPATH="" \
      PYTEST_ADDOPTS="" \
      FAKE_LOG_DIR="$CURRENT_CASE_DIR/logs" \
      FAKE_SITE_PACKAGES="$CURRENT_CASE_DIR/site-packages" \
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

# Validate the happy path: only ddtrace is installed and the right environment
# variables are printed. This is the main regression guard against reintroducing
# a forced `coverage` installation.
scenario_latest_ddtrace() {
  prepare_case "latest_ddtrace"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=python \
    FAKE_DDTRACE_VERSION=3.9.2

  assert_exit_code 0
  assert_file_contains "$CURRENT_CASE_DIR/logs/pip.log" "install -U ddtrace"
  assert_file_not_contains "$CURRENT_CASE_DIR/logs/pip.log" "install -U ddtrace=="
  assert_file_contains "$LAST_STDOUT" "PYTHONPATH=$CURRENT_CASE_DIR/site-packages:"
  assert_file_contains "$LAST_STDOUT" "PYTEST_ADDOPTS=--ddtrace "
  assert_file_contains "$LAST_STDOUT" "DD_TRACER_VERSION_PYTHON=3.9.2"
  assert_no_coverage
}

# Validate that DD_SET_TRACER_VERSION_PYTHON pins the ddtrace version and that
# no extra package (in particular coverage) is installed alongside it.
scenario_pinned_ddtrace_version() {
  prepare_case "pinned_ddtrace_version"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=python \
    DD_SET_TRACER_VERSION_PYTHON=2.12.0 \
    FAKE_DDTRACE_VERSION=2.12.0

  assert_exit_code 0
  assert_file_contains "$CURRENT_CASE_DIR/logs/pip.log" "install -U ddtrace==2.12.0"
  assert_file_contains "$LAST_STDOUT" "PYTHONPATH=$CURRENT_CASE_DIR/site-packages:"
  assert_file_contains "$LAST_STDOUT" "DD_TRACER_VERSION_PYTHON=2.12.0"
  assert_no_coverage
}

# Validate the failure path when pip is not available on the system.
scenario_pip_not_installed() {
  prepare_case "pip_not_installed"
  # Simulate a machine without pip: remove it from the fake toolchain and use
  # a restricted PATH so no system pip can be picked up either.
  rm "$CURRENT_CASE_DIR/bin/pip"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=python \
    FAKE_RESTRICTED_PATH=1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: pip is not installed."
  assert_file_not_contains "$LAST_STDOUT" "PYTHONPATH="
  assert_file_not_contains "$LAST_STDOUT" "PYTEST_ADDOPTS="
}

# Validate the failure path when ddtrace cannot be installed.
scenario_pip_install_fails() {
  prepare_case "pip_install_fails"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=python \
    FAKE_FAIL_PIP_INSTALL=1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: Could not install ddtrace for Python"
  assert_file_not_contains "$LAST_STDOUT" "PYTHONPATH="
  assert_file_not_contains "$LAST_STDOUT" "DD_TRACER_VERSION_PYTHON="
  assert_no_coverage
}

# Validate the failure path when the ddtrace package location cannot be resolved.
scenario_ddtrace_location_not_found() {
  prepare_case "ddtrace_location_not_found"

  run_install_script \
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=python \
    FAKE_PIP_SHOW_LOCATION="$CURRENT_CASE_DIR/missing-site-packages"

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: Could not determine ddtrace package location (tried $CURRENT_CASE_DIR/missing-site-packages)"
  assert_file_not_contains "$LAST_STDOUT" "PYTHONPATH="
  assert_file_not_contains "$LAST_STDOUT" "DD_TRACER_VERSION_PYTHON="
  assert_no_coverage
}

main() {
  run_case "latest_ddtrace" scenario_latest_ddtrace
  run_case "pinned_ddtrace_version" scenario_pinned_ddtrace_version
  run_case "pip_not_installed" scenario_pip_not_installed
  run_case "pip_install_fails" scenario_pip_install_fails
  run_case "ddtrace_location_not_found" scenario_ddtrace_location_not_found

  printf '\nPython matrix: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
