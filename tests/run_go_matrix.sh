#!/bin/bash

# This harness validates the Go installation decision matrix by running the
# install script against fake curl, go and uname commands and a fake ddtest
# release. That keeps the tests deterministic while still exercising the full
# shell control flow. tests/run_go_smoke.sh runs the real ddtest.

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
# Print the SHA-256 digest of a file.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 < "$1" | cut -d ' ' -f 1
  fi
}

# Write a simple go.mod file that includes a go directive.
write_go_mod() {
  local file_path="$1"
  local module_name="$2"
  local go_version="$3"
  cat > "$file_path" <<MOD
module $module_name

go $go_version
MOD
}

# Create the fake commands and the fake ddtest release used by one scenario.
# Scenarios run as a linux/amd64 host unless they fake uname, so the release
# has ddtest-linux-amd64 and, for Windows, the same fake as
# ddtest-windows-amd64.exe.
create_fake_toolchain() {
  mkdir -p "$CURRENT_CASE_DIR/bin" "$CURRENT_CASE_DIR/logs" "$CURRENT_CASE_DIR/release"

  # The fake ddtest runs commands as ddtest instrument does: every run takes
  # the go shim off PATH, and --go-shim puts it first for its command, unless
  # the shim cannot be set up, when ddtest warns and runs the command without it.
  cat > "$CURRENT_CASE_DIR/release/ddtest-linux-amd64" <<'DDTEST'
#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
  echo "${FAKE_DDTEST_VERSION:-v1.16.0}"
  exit 0
fi
if [ "${1:-}" != "instrument" ]; then
  echo "Unsupported fake ddtest command: ddtest $*" >&2
  exit 2
fi
shift

kept=""
IFS=: read -r -a entries <<< "$PATH"
for entry in "${entries[@]}"; do
  if [ "$entry" != "$FAKE_GO_SHIM_DIR" ]; then
    kept="${kept:+$kept:}$entry"
  fi
done
PATH="$kept"

if [ "${1:-}" = "--go-shim" ]; then
  shift
  if [ "${FAKE_GO_SHIM_FAILS:-0}" = "1" ]; then
    echo "TestOptimization.build WARN: cannot set up the go shim - running $1 without Test Optimization" >&2
  else
    mkdir -p "$FAKE_GO_SHIM_DIR"
    printf '#!/bin/sh\necho "fake go shim $*"\n' > "$FAKE_GO_SHIM_DIR/go"
    chmod +x "$FAKE_GO_SHIM_DIR/go"
    PATH="$FAKE_GO_SHIM_DIR:$PATH"
  fi
fi
export PATH
exec "$@"
DDTEST
  sha256_of "$CURRENT_CASE_DIR/release/ddtest-linux-amd64" > "$CURRENT_CASE_DIR/release/ddtest.sha256"
  cp "$CURRENT_CASE_DIR/release/ddtest-linux-amd64" "$CURRENT_CASE_DIR/release/ddtest-windows-amd64.exe"

  cat > "$CURRENT_CASE_DIR/bin/curl" <<'EOF_CURL'
#!/bin/bash
set -euo pipefail

# download_file runs curl -fLo <file> <url>.
url="${@: -1}"
output="${@: -2:1}"
printf '%s\n' "$url" >> "$FAKE_LOG_DIR/curl.log"

# curl -f exits 22 when the server answers with an error, such as 404 for a
# release that does not exist, and with other codes when the network fails.
if [ "${FAKE_FAIL_DOWNLOADS:-0}" = "1" ]; then
  exit "${FAKE_DOWNLOAD_EXIT:-22}"
fi
if [ -n "${FAKE_MISSING_RELEASE:-}" ] && [[ "$url" == */download/"$FAKE_MISSING_RELEASE"/* ]]; then
  exit 22
fi

case "$url" in
  https://github.com/DataDog/ddtest/releases/*/SHA256SUMS)
    checksum="$(cat "$FAKE_RELEASE_DIR/ddtest.sha256")"
    if [ "${FAKE_BAD_CHECKSUM:-0}" = "1" ]; then
      checksum="0000000000000000000000000000000000000000000000000000000000000000"
    fi
    {
      printf '%s  ddtest-darwin-arm64\n' "$checksum"
      if [ "${FAKE_SUMS_WITHOUT_ASSET:-0}" != "1" ]; then
        printf '%s  ddtest-linux-amd64\n' "$checksum"
        printf '%s *ddtest-windows-amd64.exe\n' "$checksum"
      fi
    } > "$output"
    ;;
  https://github.com/DataDog/ddtest/releases/*/ddtest-linux-amd64 | https://github.com/DataDog/ddtest/releases/*/ddtest-windows-amd64.exe)
    if [ "${FAKE_FAIL_ASSET_DOWNLOAD:-0}" = "1" ]; then
      # curl keeps what arrived before a transfer error.
      printf 'partial' > "$output"
      exit 18
    fi
    cp "$FAKE_RELEASE_DIR/${url##*/}" "$output"
    ;;
  *)
    echo "Unsupported fake curl request: $url" >&2
    exit 1
    ;;
esac
EOF_CURL
  chmod +x "$CURRENT_CASE_DIR/bin/curl"

  cat > "$CURRENT_CASE_DIR/bin/go" <<'EOF_GO'
#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "version" ]; then
  if [ "${FAKE_GO_VERSION_FAILS:-0}" = "1" ]; then
    echo "go: download go1.26.0: connection refused" >&2
    exit 1
  fi
  printf '%s\n' "${FAKE_GO_VERSION_LINE:-go version go${FAKE_GO_VERSION:-1.26.1} linux/amd64}"
  exit 0
fi
printf '%s\n' "$*" >> "$FAKE_LOG_DIR/go.log"
echo "Unsupported fake go command: go $*" >&2
exit 95
EOF_GO
  chmod +x "$CURRENT_CASE_DIR/bin/go"

  cat > "$CURRENT_CASE_DIR/bin/uname" <<'EOF_UNAME'
#!/bin/bash
case "${1:-}" in
  -s) echo "${FAKE_UNAME_S:-Linux}" ;;
  -m) echo "${FAKE_UNAME_M:-x86_64}" ;;
  *) echo "Unsupported fake uname invocation: uname $*" >&2; exit 1 ;;
esac
EOF_UNAME
  chmod +x "$CURRENT_CASE_DIR/bin/uname"

  # Git Bash's cygpath -w turns a POSIX path into a Windows one.
  cat > "$CURRENT_CASE_DIR/bin/cygpath" <<'EOF_CYGPATH'
#!/bin/bash
if [ "${1:-}" != "-w" ] || [ $# -ne 2 ]; then
  echo "Unsupported fake cygpath invocation: cygpath $*" >&2
  exit 1
fi
printf 'C:%s\n' "$(printf '%s' "$2" | tr '/' '\\')"
EOF_CYGPATH
  chmod +x "$CURRENT_CASE_DIR/bin/cygpath"
}

# Create a clean per-scenario workspace and fake toolchain.
prepare_case() {
  local case_name="$1"
  CURRENT_CASE_DIR="$TEST_ROOT/$case_name"
  CURRENT_WORKSPACE="$CURRENT_CASE_DIR/workspace"
  mkdir -p "$CURRENT_WORKSPACE"
  create_fake_toolchain
  write_go_mod "$CURRENT_WORKSPACE/go.mod" "example.com/root" "1.22"
  cp "$CURRENT_WORKSPACE/go.mod" "$CURRENT_CASE_DIR/initial.go.mod"
}

# Run the install script inside the current scenario workspace, outside GitHub
# Actions unless a scenario sets GITHUB_PATH: the harness itself can run there.
run_install_script() {
  LAST_STDOUT="$CURRENT_CASE_DIR/stdout.txt"
  LAST_STDERR="$CURRENT_CASE_DIR/stderr.txt"

  set +e
  (
    cd "$CURRENT_WORKSPACE" &&
    env -u GITHUB_PATH -u GITHUB_ACTION \
      PATH="$CURRENT_CASE_DIR/bin:$PATH" \
      FAKE_LOG_DIR="$CURRENT_CASE_DIR/logs" \
      FAKE_RELEASE_DIR="$CURRENT_CASE_DIR/release" \
      FAKE_GO_SHIM_DIR="$CURRENT_CASE_DIR/go-shim" \
      DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=go \
      "$@" \
      bash "$SCRIPT_UNDER_TEST" > "$LAST_STDOUT" 2> "$LAST_STDERR"
  )
  LAST_EXIT_CODE=$?
  set -e
}

# Assert that every line on stdout is a variable assignment, the script's
# contract with its consumers.
assert_stdout_is_assignments() {
  if grep -v -E '^[A-Za-z_][A-Za-z0-9_]*=' "$LAST_STDOUT" >&2; then
    fail "stdout has lines that are not variable assignments"
  fi
}

# Assert that the script printed nothing for Go and left the project as it was.
assert_go_not_instrumented() {
  assert_stdout_is_assignments
  assert_file_not_contains "$LAST_STDOUT" "PATH="
  assert_file_not_contains "$LAST_STDOUT" "DD_TRACER_VERSION_GO="
  assert_file_not_contains "$LAST_STDOUT" "GOFLAGS="
  assert_files_equal "$CURRENT_CASE_DIR/initial.go.mod" "$CURRENT_WORKSPACE/go.mod"
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

# Validate the default path: the latest ddtest release is installed and its go
# shim comes first on the printed PATH, without touching the project.
scenario_latest_release() {
  prepare_case "latest_release"

  run_install_script

  assert_exit_code 0
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/latest/download/SHA256SUMS"
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/latest/download/ddtest-linux-amd64"
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
  assert_file_contains "$LAST_STDOUT" "DD_TRACER_VERSION_GO=v1.16.0"
  assert_file_not_contains "$LAST_STDOUT" "GOFLAGS="
  assert_files_equal "$CURRENT_CASE_DIR/release/ddtest-linux-amd64" "$CURRENT_WORKSPACE/.datadog/ddtest"
  if [ ! -x "$CURRENT_WORKSPACE/.datadog/ddtest" ]; then
    fail "ddtest is not executable"
  fi
  assert_file_missing "$CURRENT_WORKSPACE/.datadog/ddtest.SHA256SUMS"
  assert_files_equal "$CURRENT_CASE_DIR/initial.go.mod" "$CURRENT_WORKSPACE/go.mod"
  assert_file_missing "$CURRENT_CASE_DIR/logs/go.log"

  # A job that exports the printed PATH runs the go shim as go.
  local printed_path
  printed_path="$(sed -n 's/^PATH=//p' "$LAST_STDOUT")"
  if [ "$(PATH="$printed_path" command -v go)" != "$CURRENT_CASE_DIR/go-shim/go" ]; then
    fail "the printed PATH does not run the go shim as go"
  fi
}

# Validate that a pinned release is downloaded from its own release page, also
# without the v prefix, into DD_TRACER_FOLDER.
scenario_pinned_release() {
  prepare_case "pinned_release"

  run_install_script \
    DD_SET_TRACER_VERSION_GO=1.14.0 \
    DD_TRACER_FOLDER="$CURRENT_CASE_DIR/tracers" \
    FAKE_DDTEST_VERSION=v1.14.0

  assert_exit_code 0
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/download/v1.14.0/SHA256SUMS"
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/download/v1.14.0/ddtest-linux-amd64"
  assert_file_exists "$CURRENT_CASE_DIR/tracers/ddtest"
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
  assert_file_contains "$LAST_STDOUT" "DD_TRACER_VERSION_GO=v1.14.0"
}

# Validate that a release older than ddtest instrument, such as an earlier
# Orchestrion pin, installs the latest ddtest with a warning.
scenario_release_before_instrument_installs_latest() {
  prepare_case "release_before_instrument_installs_latest"

  run_install_script DD_SET_TRACER_VERSION_GO=v1.8.0

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Warning: DD_SET_TRACER_VERSION_GO=v1.8.0 is not a ddtest release from v1.14.0 on; ddtest replaced Orchestrion for Go. Installing the latest ddtest release."
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/latest/download/ddtest-linux-amd64"
  assert_file_not_contains "$CURRENT_CASE_DIR/logs/curl.log" "/download/v1.8.0/"
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
}

# Validate that a value that is not a release tag, such as an Orchestrion
# commit, does the same.
scenario_commit_version_installs_latest() {
  prepare_case "commit_version_installs_latest"

  run_install_script DD_SET_TRACER_VERSION_GO=0123abc

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Warning: DD_SET_TRACER_VERSION_GO=0123abc is not a ddtest release"
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/latest/download/ddtest-linux-amd64"
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
}

# Validate that a runner whose Go toolchain is older than ddtest needs is skipped.
scenario_runner_go_below_minimum() {
  prepare_case "runner_go_below_minimum"

  run_install_script FAKE_GO_VERSION=1.24.5

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Warning: The installed Go version (1.24.5) is lower than the Go 1.25.0 that ddtest instrument needs."
  assert_file_contains "$LAST_STDERR" "Skipping Go instrumentation."
  assert_file_missing "$CURRENT_CASE_DIR/logs/curl.log"
  assert_go_not_instrumented
}

# Validate that a host without a ddtest release executable is skipped.
scenario_unsupported_platform() {
  prepare_case "unsupported_platform"

  run_install_script FAKE_UNAME_S=FreeBSD

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Warning: ddtest has no release executable for FreeBSD x86_64."
  assert_file_contains "$LAST_STDERR" "Skipping Go instrumentation."
  assert_file_missing "$CURRENT_CASE_DIR/logs/curl.log"
  assert_go_not_instrumented
}

# Put an earlier installation's ddtest in the workspace's .datadog folder.
install_previous_ddtest() {
  mkdir -p "$CURRENT_WORKSPACE/.datadog"
  printf 'previous ddtest\n' > "$CURRENT_WORKSPACE/.datadog/ddtest"
  cp "$CURRENT_WORKSPACE/.datadog/ddtest" "$CURRENT_CASE_DIR/previous-ddtest"
}

# Assert that the earlier installation's ddtest, which its go shims link to,
# is still there, and that no download is left beside it.
assert_previous_ddtest_kept() {
  assert_files_equal "$CURRENT_CASE_DIR/previous-ddtest" "$CURRENT_WORKSPACE/.datadog/ddtest"
  local leftover
  for leftover in "$CURRENT_WORKSPACE"/.datadog/*; do
    if [ "$leftover" != "$CURRENT_WORKSPACE/.datadog/ddtest" ]; then
      fail "left behind: $leftover"
    fi
  done
}

# Validate that an executable that does not match SHA256SUMS does not replace
# the installed one.
scenario_checksum_mismatch() {
  prepare_case "checksum_mismatch"
  install_previous_ddtest

  run_install_script FAKE_BAD_CHECKSUM=1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "ddtest-linux-amd64 does not match the checksum in the ddtest release."
  assert_previous_ddtest_kept
  assert_go_not_instrumented
}

# Validate that an interrupted download does not replace the installed ddtest.
scenario_interrupted_download() {
  prepare_case "interrupted_download"
  install_previous_ddtest

  run_install_script FAKE_FAIL_ASSET_DOWNLOAD=1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: Could not download https://github.com/DataDog/ddtest/releases/latest/download/ddtest-linux-amd64."
  assert_previous_ddtest_kept
  assert_go_not_instrumented
}

# Validate that a go that cannot report its version fails the installation
# instead of being skipped as too old.
scenario_go_version_fails() {
  prepare_case "go_version_fails"

  run_install_script FAKE_GO_VERSION_FAILS=1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: go version failed."
  assert_file_not_contains "$LAST_STDERR" "Skipping Go instrumentation."
  assert_go_not_instrumented
}

# Validate that a development build of the minimum Go comes before it.
scenario_runner_go_minimum_development_build() {
  prepare_case "runner_go_minimum_development_build"

  run_install_script FAKE_GO_VERSION_LINE="go version devel go1.25-0123abc Tue Nov 4 10:00:00 2025 +0000 linux/amd64"

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Warning: The installed Go version (1.25) is lower than the Go 1.25.0 that ddtest instrument needs."
  assert_go_not_instrumented
}

# Validate that a development build of a later Go than the minimum is enough.
scenario_runner_go_later_development_build() {
  prepare_case "runner_go_later_development_build"

  run_install_script FAKE_GO_VERSION_LINE="go version devel go1.26-0123abc Tue Nov 4 10:00:00 2025 +0000 linux/amd64"

  assert_exit_code 0
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
}

# Validate that a release without an executable for the host fails.
scenario_release_without_asset() {
  prepare_case "release_without_asset"

  run_install_script FAKE_SUMS_WITHOUT_ASSET=1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "has no ddtest-linux-amd64"
  assert_file_missing "$CURRENT_WORKSPACE/.datadog/ddtest"
  assert_go_not_instrumented
}

# Validate that a failed download fails the installation.
scenario_download_failure() {
  prepare_case "download_failure"

  run_install_script FAKE_FAIL_DOWNLOADS=1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: Could not download https://github.com/DataDog/ddtest/releases/latest/download/SHA256SUMS."
  assert_go_not_instrumented
}

# Validate that ddtest running the command without its go shim fails the
# installation instead of printing a PATH that does not instrument go test.
scenario_go_shim_unavailable() {
  prepare_case "go_shim_unavailable"

  run_install_script FAKE_GO_SHIM_FAILS=1

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: ddtest could not set up its go command for Go instrumentation."
  assert_go_not_instrumented
}

# Validate that in GitHub Actions on Linux and macOS the go shim comes on the
# printed PATH, which a step that exports the output can use at once, and goes
# to GITHUB_PATH, which the next steps get before setup-go's directories.
scenario_github_actions() {
  prepare_case "github_actions"
  printf '/opt/hostedtoolcache/go/bin\n' > "$CURRENT_CASE_DIR/github_path"

  run_install_script GITHUB_PATH="$CURRENT_CASE_DIR/github_path"

  assert_exit_code 0
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
  assert_files_equal <(printf '/opt/hostedtoolcache/go/bin\n%s\n' "$CURRENT_CASE_DIR/go-shim") "$CURRENT_CASE_DIR/github_path"
}

# Validate that a DD_TRACER_FOLDER with spaces, not created yet, holds ddtest.
scenario_tracer_folder_with_spaces() {
  prepare_case "tracer_folder_with_spaces"

  run_install_script DD_TRACER_FOLDER="$CURRENT_CASE_DIR/tracer folder/datadog"

  assert_exit_code 0
  assert_file_exists "$CURRENT_CASE_DIR/tracer folder/datadog/ddtest"
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
}

# Validate that a release candidate of an older Go counts as that older Go.
scenario_runner_go_release_candidate_below_minimum() {
  prepare_case "runner_go_release_candidate_below_minimum"

  run_install_script FAKE_GO_VERSION=1.24rc1

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Warning: The installed Go version (1.24rc1) is lower than the Go 1.25.0 that ddtest instrument needs."
  assert_file_missing "$CURRENT_CASE_DIR/logs/curl.log"
  assert_go_not_instrumented
}

# Validate that a release candidate of the minimum Go comes before it.
scenario_runner_go_minimum_release_candidate() {
  prepare_case "runner_go_minimum_release_candidate"

  run_install_script FAKE_GO_VERSION=1.25rc1

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Warning: The installed Go version (1.25rc1) is lower than the Go 1.25.0 that ddtest instrument needs."
  assert_go_not_instrumented
}

# Validate that a release candidate of a later Go than the minimum is enough.
scenario_runner_go_later_release_candidate() {
  prepare_case "runner_go_later_release_candidate"

  run_install_script FAKE_GO_VERSION=1.26rc1

  assert_exit_code 0
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
}

# Validate that Git Bash on Windows installs ddtest.exe and, outside GitHub
# Actions, prints the go shim on a PATH in the shell's own POSIX form.
scenario_windows_shell() {
  prepare_case "windows_shell"

  run_install_script FAKE_UNAME_S=MINGW64_NT-10.0-20348

  assert_exit_code 0
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/latest/download/ddtest-windows-amd64.exe"
  assert_file_exists "$CURRENT_WORKSPACE/.datadog/ddtest.exe"
  assert_file_missing "$CURRENT_WORKSPACE/.datadog/ddtest"
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
}

# Validate that in GitHub Actions on Windows the go shim goes to GITHUB_PATH as
# a Windows path, which the runner's later steps, in any shell, can read.
scenario_windows_github_actions() {
  prepare_case "windows_github_actions"
  touch "$CURRENT_CASE_DIR/github_path"

  run_install_script \
    FAKE_UNAME_S=MINGW64_NT-10.0-20348 \
    GITHUB_PATH="$CURRENT_CASE_DIR/github_path"

  assert_exit_code 0
  assert_files_equal <(printf 'C:%s\n' "$(printf '%s' "$CURRENT_CASE_DIR/go-shim" | tr '/' '\\')") "$CURRENT_CASE_DIR/github_path"
  assert_file_not_contains "$LAST_STDOUT" "PATH="
}

# Validate that a pinned release that ddtest never published installs the
# latest ddtest with a warning.
scenario_missing_release_installs_latest() {
  prepare_case "missing_release_installs_latest"

  run_install_script DD_SET_TRACER_VERSION_GO=v1.99.0 FAKE_MISSING_RELEASE=v1.99.0

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Warning: DD_SET_TRACER_VERSION_GO=v1.99.0 is not a ddtest release from v1.14.0 on"
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/download/v1.99.0/SHA256SUMS"
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/latest/download/ddtest-linux-amd64"
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
}

# Validate that a network failure for a pinned release stays an error instead
# of installing another release.
scenario_pinned_release_network_failure() {
  prepare_case "pinned_release_network_failure"

  run_install_script DD_SET_TRACER_VERSION_GO=v1.16.0 FAKE_FAIL_DOWNLOADS=1 FAKE_DOWNLOAD_EXIT=7

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: Could not download https://github.com/DataDog/ddtest/releases/download/v1.16.0/SHA256SUMS."
  assert_file_not_contains "$CURRENT_CASE_DIR/logs/curl.log" "/latest/"
  assert_go_not_instrumented
}

# Validate that curl's exit status 8, a reply it could not parse, for a pinned
# release stays an error: only wget's 8 means the server answered with one.
scenario_pinned_release_unparseable_reply() {
  prepare_case "pinned_release_unparseable_reply"

  run_install_script DD_SET_TRACER_VERSION_GO=v1.16.0 FAKE_FAIL_DOWNLOADS=1 FAKE_DOWNLOAD_EXIT=8

  assert_exit_code 1
  assert_file_contains "$LAST_STDERR" "Error: Could not download https://github.com/DataDog/ddtest/releases/download/v1.16.0/SHA256SUMS."
  assert_file_not_contains "$CURRENT_CASE_DIR/logs/curl.log" "/latest/"
  assert_go_not_instrumented
}

# Replace curl with wget for one scenario: PATH holds only the fake commands
# and the system commands that the script and the fakes run, so the script
# cannot find a real curl. The fake wget serves the same release as the fake
# curl and reports a server error with wget's exit status 8.
use_wget_instead_of_curl() {
  mkdir -p "$CURRENT_CASE_DIR/system-bin"
  local tool
  local tool_path
  for tool in awk basename bash cat chmod cmp cp cut dirname env grep head mkdir mv rm sed sh sha256sum shasum sort touch tr; do
    if tool_path="$(command -v "$tool")"; then
      ln -s "$tool_path" "$CURRENT_CASE_DIR/system-bin/$tool"
    fi
  done
  mv "$CURRENT_CASE_DIR/bin/curl" "$CURRENT_CASE_DIR/bin/fake-download"
  cat > "$CURRENT_CASE_DIR/bin/wget" <<'EOF_WGET'
#!/bin/bash
# download_file runs wget -O <file> <url>, which the fake curl also reads.
status=0
"$(dirname "$0")/fake-download" "$@" || status=$?
if [ "$status" -eq 22 ]; then
  exit 8
fi
exit "$status"
EOF_WGET
  chmod +x "$CURRENT_CASE_DIR/bin/wget"
}

# Validate that with wget, whose exit status 8 means the server answered with
# an error, a pinned release that ddtest never published installs the latest.
scenario_wget_missing_release_installs_latest() {
  prepare_case "wget_missing_release_installs_latest"
  use_wget_instead_of_curl

  run_install_script \
    PATH="$CURRENT_CASE_DIR/bin:$CURRENT_CASE_DIR/system-bin" \
    DD_SET_TRACER_VERSION_GO=v1.99.0 \
    FAKE_MISSING_RELEASE=v1.99.0

  assert_exit_code 0
  assert_file_contains "$LAST_STDERR" "Warning: DD_SET_TRACER_VERSION_GO=v1.99.0 is not a ddtest release from v1.14.0 on"
  assert_file_contains "$CURRENT_CASE_DIR/logs/curl.log" "https://github.com/DataDog/ddtest/releases/latest/download/ddtest-linux-amd64"
  assert_file_contains "$LAST_STDOUT" "PATH=$CURRENT_CASE_DIR/go-shim:"
}

main() {
  run_case "latest_release" scenario_latest_release
  run_case "pinned_release" scenario_pinned_release
  run_case "release_before_instrument_installs_latest" scenario_release_before_instrument_installs_latest
  run_case "commit_version_installs_latest" scenario_commit_version_installs_latest
  run_case "missing_release_installs_latest" scenario_missing_release_installs_latest
  run_case "pinned_release_network_failure" scenario_pinned_release_network_failure
  run_case "pinned_release_unparseable_reply" scenario_pinned_release_unparseable_reply
  run_case "wget_missing_release_installs_latest" scenario_wget_missing_release_installs_latest
  run_case "runner_go_below_minimum" scenario_runner_go_below_minimum
  run_case "unsupported_platform" scenario_unsupported_platform
  run_case "checksum_mismatch" scenario_checksum_mismatch
  run_case "interrupted_download" scenario_interrupted_download
  run_case "go_version_fails" scenario_go_version_fails
  run_case "runner_go_minimum_development_build" scenario_runner_go_minimum_development_build
  run_case "runner_go_later_development_build" scenario_runner_go_later_development_build
  run_case "release_without_asset" scenario_release_without_asset
  run_case "download_failure" scenario_download_failure
  run_case "go_shim_unavailable" scenario_go_shim_unavailable
  run_case "github_actions" scenario_github_actions
  run_case "tracer_folder_with_spaces" scenario_tracer_folder_with_spaces
  run_case "runner_go_release_candidate_below_minimum" scenario_runner_go_release_candidate_below_minimum
  run_case "runner_go_minimum_release_candidate" scenario_runner_go_minimum_release_candidate
  run_case "runner_go_later_release_candidate" scenario_runner_go_later_release_candidate
  run_case "windows_shell" scenario_windows_shell
  run_case "windows_github_actions" scenario_windows_github_actions

  printf '\nGo matrix: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
