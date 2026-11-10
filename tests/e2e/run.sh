#!/usr/bin/env bash
# End-to-end test of the installer for one language, with the real libraries.
#
#   tests/e2e/run.sh <language> shell
#   tests/e2e/run.sh <language> github-install   (in a GitHub Actions step)
#   tests/e2e/run.sh <language> github-test      (in a later step of that job)
#   tests/e2e/run.sh <language> gitlab
#   tests/e2e/run.sh <language> circleci
#   tests/e2e/run.sh <language> prepare                     (E2E_PROJECT)
#   tests/e2e/run.sh <language> patch-github-action <dir>
#   tests/e2e/run.sh <language> test                        (E2E_PROJECT)
#   tests/e2e/run.sh go skipped                             (Go older than 1.25)
#
# Each run builds a small project with one passing test for the language, runs
# the installer from the project, runs the project's tests with what the
# installer configured, and checks that the test's event, found by the
# test's name (DdE2eMarker), reached a local stand-in for Datadog's intake
# (tests/e2e/intake.py). No backend or real API key is needed.
#
# The modes consume the installer's output as its users do:
#
# - shell exports every printed variable in the same shell, as the README
#   shows, outside GitHub Actions.
# - github-install appends the output to GITHUB_ENV, as the GitHub action does,
#   and github-test runs the tests in the job's next step, which also gets what
#   the installer added to GITHUB_PATH.
# - gitlab and circleci run the real wrappers, the GitLab script
#   (E2E_GITLAB_SCRIPT, its script.sh) and the CircleCI orb's script
#   (E2E_CIRCLECI_SCRIPT, its src/scripts/autoinstrument.sh), as those CI
#   systems do, with only the installer's URL and checksum changed to this
#   installer, which the intake serves.
# - skipped runs the installer with a Go too old for ddtest instrument, which it
#   skips with a warning and exit status 0, and then the tests, which still
#   pass, without Test Optimization.
# - prepare, patch-github-action and test run the real GitHub action across a
#   job's steps: prepare writes the project in E2E_PROJECT, the workspace that
#   the action installs from; patch-github-action points a checkout of the
#   action at this installer; a later step uses the action; test then runs the
#   tests.
#
# Languages: go, python, js, java, dotnet, ruby. The runner needs the
# language's toolchain: Go 1.25 or newer, Python with venv, Node.js with npm,
# a JDK with Maven, the .NET SDK, or Ruby with Bundler; and Python for the
# intake. E2E_DIR (default $RUNNER_TEMP/dd-e2e, else a new temporary
# directory) holds the projects and the intake's files. E2E_TRACER_FOLDER, if
# set, becomes the installer's DD_TRACER_FOLDER, such as a folder with spaces.
# E2E_INSTALL_TWICE=1 makes shell mode run the installer a second time with the
# first run's output exported, as a persistent runner or a retry does.
# E2E_EXPECT_DDTEST_VERSION, for Go, is the ddtest release that the installer
# must have installed, or latest for the newest release.
# E2E_GO_MIRROR=1 makes shell mode for Go install ddtest from a mirror of its
# releases that the intake serves, through DD_SET_TRACER_REPOSITORY_URL_GO,
# with every other host behind a proxy that refuses connections; the mirror
# requires the token that DD_SET_AUTH_HEADER_GO sends.
# E2E_GO_RUNNER picks how Go runs its tests: go (go test, the default);
# gotestsum as a binary that go install put on disk, as gotestsum-go-run with
# go run, or as gotestsum-go-tool, a tool of the module; script, a shell script
# that runs go test; make, a make target that does; subdir, with the module in
# services/payments, where the tests run after cd; go-C, the same module run
# with go -C; or toolchain, a go.mod whose toolchain line, newer than the
# runner's Go, makes go switch to that toolchain (GOTOOLCHAIN=auto).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="${INSTALLER_UNDER_TEST:-$repo_root/install_test_visibility.sh}"
usage="usage: run.sh <language> shell|github-install|github-test|gitlab|circleci|prepare|patch-github-action <dir>|test"
language="${1:?$usage}"
mode="${2:?$usage}"

fail() {
  echo "FAIL ($language, $mode): $*" >&2
  exit 1
}

case "$language" in
  go|python|js|java|dotnet|ruby) ;;
  *) fail "unknown language" ;;
esac

if [ -n "${E2E_DIR:-}" ]; then
  mkdir -p "$E2E_DIR"
elif [ -n "${RUNNER_TEMP:-}" ]; then
  E2E_DIR="$RUNNER_TEMP/dd-e2e"
  mkdir -p "$E2E_DIR"
else
  E2E_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dd-e2e.XXXXXX")"
fi
# Each variant of a mode has its own project and intake folders: on Windows a
# folder that a process of an earlier step still uses cannot be removed.
variant=""
if [ -n "${E2E_GO_RUNNER:-}" ] && [ "$E2E_GO_RUNNER" != "go" ]; then
  variant="$variant-$E2E_GO_RUNNER"
fi
if [ "${E2E_INSTALL_TWICE:-}" = "1" ]; then
  variant="$variant-twice"
fi
if [ "${E2E_GO_MIRROR:-}" = "1" ]; then
  variant="$variant-mirror"
fi
if [ -n "${E2E_TRACER_FOLDER:-}" ]; then
  variant="$variant-$(basename "$E2E_TRACER_FOLDER" | tr -c 'A-Za-z0-9\n' '-')"
fi
project="${E2E_PROJECT:-$E2E_DIR/$language-$mode$variant}"
if [ "$mode" = "github-test" ] && [ -z "${E2E_PROJECT:-}" ]; then
  project="$E2E_DIR/$language-github-install$variant"
fi

is_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the SHA-256 digest of a file.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 < "$1" | cut -d ' ' -f 1
  fi
}

# The settings that every run uses: delivery goes to the local intake, with a
# placeholder API key.
export DD_API_KEY=dummy
export DD_SERVICE="install-script-e2e-$language"
export DD_CIVISIBILITY_GIT_UPLOAD_ENABLED=false
export DD_INSTRUMENTATION_TELEMETRY_ENABLED=false
export DD_REMOTE_CONFIGURATION_ENABLED=false
if [ -n "${E2E_TRACER_FOLDER:-}" ]; then
  export DD_TRACER_FOLDER="$E2E_TRACER_FOLDER"
fi

# An older go directive than ddtest's own toolchain requirement: the Go project
# keeps its language version, and the installer must not change the file.
go_mod="$(printf 'module example.com/e2e\n\ngo 1.22')"
go_runner="${E2E_GO_RUNNER:-go}"
gotestsum_module="gotest.tools/gotestsum@v1.13.0"
# Newer than the Go 1.25 that the workflow sets up.
go_toolchain="go1.26.0"
go_module_dir="."
case "$go_runner" in
  subdir|go-C) go_module_dir="services/payments" ;;
  toolchain) export GOTOOLCHAIN=auto ;;
esac

activate_python_venv() {
  if is_windows; then
    # shellcheck disable=SC1091
    source app/Scripts/activate
  else
    # shellcheck disable=SC1091
    source app/bin/activate
  fi
}

# Write the project for the language in the current directory and install
# its test framework.
prepare_project() {
  case "$language" in
    go)
      mkdir -p "$go_module_dir"
      printf '%s\n' "$go_mod" > "$go_module_dir/go.mod"
      if [ "$go_runner" = "toolchain" ]; then
        printf 'toolchain %s\n' "$go_toolchain" >> go.mod
      fi
      cat > "$go_module_dir/e2e_test.go" <<'GO'
package e2e

import (
	"os"
	"testing"
)

func TestDdE2eMarker(t *testing.T) {
	if os.Getenv("E2E_FAIL") == "1" {
		t.Fatal("failing on purpose")
	}
}
GO
      # gotestsum is installed before the installer runs, with the
      # toolchain's go, as a project's CI would.
      case "$go_runner" in
        go|gotestsum-go-run|subdir|go-C|toolchain) ;;
        gotestsum) GOBIN="$E2E_DIR/bin" go install "$gotestsum_module" >&2 ;;
        gotestsum-go-tool) go get -tool "$gotestsum_module" >&2 ;;
        script) printf '#!/usr/bin/env bash\nset -e\ngo test -count=1 ./...\n' > run-tests.sh ;;
        make) printf 'test:\n\tgo test -count=1 ./...\n' > Makefile ;;
        *) fail "unknown E2E_GO_RUNNER: $go_runner" ;;
      esac
      # What the project's go.mod holds before the installer runs.
      cp "$go_module_dir/go.mod" "$E2E_DIR/expected-go.mod"
      ;;
    python)
      python -m venv app
      activate_python_venv
      python -m pip install --quiet 'pytest==8.4.2' >&2
      printf 'def test_DdE2eMarker():\n    assert True\n' > test_e2e.py
      ;;
    js)
      cat > package.json <<'JSON'
{
  "name": "install-script-e2e",
  "private": true,
  "scripts": { "test": "mocha" },
  "devDependencies": { "mocha": "10.8.2" }
}
JSON
      mkdir test
      printf "const assert = require('assert')\n\ndescribe('e2e', () => {\n  it('DdE2eMarker', () => assert.ok(true))\n})\n" > test/e2e.test.js
      npm install --no-audit --no-fund --loglevel=error >&2
      ;;
    java)
      cat > pom.xml <<'POM'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>install-script-e2e</artifactId>
  <version>1.0</version>
  <properties>
    <maven.compiler.release>17</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <dependencies>
    <dependency>
      <groupId>org.junit.jupiter</groupId>
      <artifactId>junit-jupiter</artifactId>
      <version>5.11.4</version>
      <scope>test</scope>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.5.2</version>
      </plugin>
    </plugins>
  </build>
</project>
POM
      mkdir -p src/test/java/example
      cat > src/test/java/example/E2ETest.java <<'JAVA'
package example;

import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class E2ETest {
  @Test
  void DdE2eMarker() {
    assertTrue(true);
  }
}
JAVA
      # Download the build's plugins and dependencies before instrumenting.
      mvn -B -q test-compile >&2
      ;;
    dotnet)
      dotnet new xunit --name E2E --output . >&2
      cat > UnitTest1.cs <<'CS'
namespace E2E;

public class UnitTest1
{
    [Fact]
    public void DdE2eMarker()
    {
        Assert.True(true);
    }
}
CS
      dotnet build >&2
      ;;
    ruby)
      cat > Gemfile <<'RUBY'
source "https://rubygems.org"

gem "rspec"
gem "datadog-ci"
RUBY
      mkdir spec
      printf 'RSpec.describe "e2e" do\n  it("DdE2eMarker") { expect(true).to be(true) }\nend\n' > spec/e2e_spec.rb
      bundle config set --local path vendor/bundle >&2
      bundle install --quiet >&2
      ;;
  esac
}

# Run the project's tests as a user of the installer would, with the
# environment that it configured.
project_tests() {
  case "$language" in
    go)
      # gotestsum runs go test itself, with the go that it finds on PATH.
      case "$go_runner" in
        go) go test -count=1 ./... ;;
        gotestsum) "$E2E_DIR/bin/gotestsum" --format testname -- -count=1 ./... ;;
        gotestsum-go-run) go run "$gotestsum_module" --format testname -- -count=1 ./... ;;
        gotestsum-go-tool) go tool gotestsum --format testname -- -count=1 ./... ;;
        script) bash ./run-tests.sh ;;
        make) make test ;;
        subdir) (cd "$go_module_dir" && go test -count=1 ./...) ;;
        go-C) go -C "$go_module_dir" test -count=1 ./... ;;
        toolchain) go test -count=1 ./... ;;
      esac
      ;;
    python) python -m pytest -q ;;
    js)
      # In GitHub Actions the installer prints DD_TRACE_PACKAGE instead of
      # NODE_OPTIONS, which GITHUB_ENV cannot set, and users add it themselves.
      if [ -n "${DD_TRACE_PACKAGE:-}" ]; then
        export NODE_OPTIONS="${NODE_OPTIONS:-} -r $DD_TRACE_PACKAGE"
      fi
      npm test
      ;;
    java) mvn -B -q test ;;
    dotnet) dotnet test --no-build ;;
    ruby) bundle exec rspec ;;
  esac
}

intake_dir="$E2E_DIR/intake-$language-$mode$variant"
intake_pid=""
intake_url=""

# Stop the intake and wait until it has exited, so the next step finds its
# files and folders free.
stop_intake() {
  if [ -n "$intake_pid" ]; then
    kill "$intake_pid" 2>/dev/null || true
    wait "$intake_pid" 2>/dev/null || true
    intake_pid=""
  fi
}

# Start the intake, which also serves this installer at
# $intake_url/install_test_visibility.sh for the wrappers to download.
start_intake() {
  rm -rf "$intake_dir"
  mkdir -p "$intake_dir"
  local python_bin=""
  for candidate in python3 python; do
    if "$candidate" -c 'import sys' >/dev/null 2>&1; then
      python_bin="$candidate"
      break
    fi
  done
  [ -n "$python_bin" ] || fail "the intake needs Python"
  # Without the step's output streams: on Windows, a background process that
  # holds them keeps the GitHub Actions step running. In its own folder, not
  # the project's, which Windows could not remove while the intake runs.
  (cd "$intake_dir" && exec "$python_bin" "$repo_root/tests/e2e/intake.py" "$intake_dir/port" \
    "$intake_dir/requests.log" "$installer" "$E2E_DIR/mirror") > "$intake_dir/intake.out" 2>&1 &
  intake_pid=$!
  trap stop_intake EXIT
  local _
  for _ in $(seq 1 300); do
    [ -s "$intake_dir/port" ] && break
    sleep 0.1
  done
  if [ ! -s "$intake_dir/port" ]; then
    echo "--- intake: $(command -v "$python_bin") ($("$python_bin" --version 2>&1))" >&2
    kill -0 "$intake_pid" 2>/dev/null && echo "--- the intake is still running" >&2 || echo "--- the intake exited" >&2
    cat "$intake_dir/intake.out" >&2 2>/dev/null || true
    fail "the intake did not start"
  fi
  intake_url="http://127.0.0.1:$(cat "$intake_dir/port")"
  DD_CIVISIBILITY_AGENTLESS_URL="$intake_url"
  export DD_CIVISIBILITY_AGENTLESS_URL
}

# Print the project's files, the installer's own folder aside.
project_files() {
  local file
  for file in * .[!.]*; do
    if [ -e "$file" ] && [ "$file" != ".datadog" ]; then
      printf '%s\n' "$file"
    fi
  done
}

# Run the tests, with the intake started if it is not yet, and check that
# their events arrived.
run_tests() {
  if [ -z "$intake_pid" ]; then
    start_intake
  fi
  local files_before
  files_before="$(project_files)"

  if [ "$language" = "python" ]; then
    activate_python_venv
  fi
  local test_log="$intake_dir/tests.log"
  if ! project_tests > "$test_log" 2>&1; then
    cat "$test_log" >&2
    fail "the project's tests failed with the installer's environment"
  fi

  # The test's own event names it; a session or module event does not. The
  # payloads are binary: BusyBox's grep, on Alpine, matches bytes that are not
  # UTF-8 only in the C locale.
  if ! LC_ALL=C grep -a -q 'DdE2eMarker' "$intake_dir/requests.log.payloads" 2>/dev/null; then
    cat "$test_log" >&2
    echo "--- requests that reached the intake:" >&2
    cat "$intake_dir/requests.log" >&2 2>/dev/null || echo "(none)" >&2
    fail "the test's event did not reach the intake"
  fi

  if [ "$language" = "js" ]; then
    # The README has vitest users append --import=$DD_TRACE_ESM_IMPORT to
    # NODE_OPTIONS, which needs a URL or a path that Node can resolve on every
    # OS, without spaces that NODE_OPTIONS would split.
    if ! NODE_OPTIONS="${NODE_OPTIONS:-} --import=$DD_TRACE_ESM_IMPORT" node -e '' > "$test_log" 2>&1; then
      cat "$test_log" >&2
      fail "Node cannot --import DD_TRACE_ESM_IMPORT=$DD_TRACE_ESM_IMPORT"
    fi
  fi

  if [ "$language" = "go" ]; then
    # go test, and gotestsum around it, keep their exit status through
    # ddtest's go.
    if E2E_FAIL=1 project_tests > "$test_log" 2>&1; then
      cat "$test_log" >&2
      fail "a failing Go test must fail $go_runner"
    fi
    cmp -s "$go_module_dir/go.mod" "$E2E_DIR/expected-go.mod" || fail "go.mod changed"
    if [ -n "${E2E_EXPECT_DDTEST_VERSION:-}" ]; then
      local expected_version="$E2E_EXPECT_DDTEST_VERSION"
      if [ "$expected_version" = "latest" ]; then
        # GitHub redirects releases/latest to the newest release's tag.
        expected_version="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/DataDog/ddtest/releases/latest)"
        expected_version="${expected_version##*/}"
      fi
      [ "${DD_TRACER_VERSION_GO:-}" = "$expected_version" ] ||
        fail "ddtest ${DD_TRACER_VERSION_GO:-?} was installed, not $expected_version"
    fi
    if [ "$go_runner" = "toolchain" ]; then
      # The tests ran with the toolchain of the go.mod, not the runner's.
      [ "$(go env GOVERSION)" = "$go_toolchain" ] ||
        fail "go did not switch to $go_toolchain: $(go env GOVERSION)"
    fi
    # go test through ddtest leaves no file of its own in the project.
    [ "$(project_files)" = "$files_before" ] ||
      fail "go test changed the project's files: $(project_files | tr '\n' ' ')"
  fi

  stop_intake
  trap - EXIT
  local runner=""
  if [ "$language" = "go" ] && [ "$go_runner" != "go" ]; then
    runner=", $go_runner"
  fi
  if [ "${E2E_INSTALL_TWICE:-}" = "1" ]; then
    runner="$runner, installed twice"
  fi
  if [ "${E2E_GO_MIRROR:-}" = "1" ]; then
    grep -q '^GET /mirror/latest/download/SHA256SUMS' "$intake_dir/requests.log" ||
      fail "the installer did not download from the mirror"
    runner="$runner, from a mirror"
  fi
  echo "PASS ($language, $mode$runner): the test's event reached the intake"
}

run_installer() {
  # BusyBox's wget ignores no_proxy, so it would send the mirror's requests to
  # the proxy too: with it, the mirror is used without blocking other hosts,
  # which the curl and GNU wget runs check.
  if [ "${E2E_GO_MIRROR:-}" = "1" ] && { command -v curl >/dev/null 2>&1 || ! wget --help 2>&1 | grep -q BusyBox; }; then
    # Only the mirror, on this host, is reachable: github.com is not.
    https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
      http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 \
      no_proxy=127.0.0.1 NO_PROXY=127.0.0.1 \
      DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES="$language" bash "$installer"
    return
  fi
  DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES="$language" bash "$installer"
}

# Copy the latest ddtest release's SHA256SUMS and this host's executable into
# a mirror with the layout of ddtest's GitHub releases.
prepare_ddtest_mirror() {
  local asset
  case "$(uname -s)" in
    Linux) asset=ddtest-linux ;;
    Darwin) asset=ddtest-darwin ;;
    *) asset=ddtest-windows ;;
  esac
  case "$(uname -m)" in
    aarch64|arm64) asset="$asset-arm64" ;;
    *) asset="$asset-amd64" ;;
  esac
  if is_windows; then
    asset="$asset.exe"
  fi
  local folder="$E2E_DIR/mirror/latest/download"
  rm -rf "$E2E_DIR/mirror"
  mkdir -p "$folder"
  local file
  local url
  for file in SHA256SUMS "$asset"; do
    url="https://github.com/DataDog/ddtest/releases/latest/download/$file"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$folder/$file" "$url" || fail "could not copy $file into the mirror"
    else
      wget -q -O "$folder/$file" "$url" || fail "could not copy $file into the mirror"
    fi
  done
}

# Make an empty project directory, write the project in it and enter it.
new_project() {
  rm -rf "$project"
  mkdir -p "$project"
  cd "$project"
  prepare_project
}

case "$mode" in
  shell)
    new_project
    # Outside GitHub Actions, even when this test runs there.
    unset GITHUB_ACTION GITHUB_PATH GITHUB_ENV
    runs=1
    if [ "${E2E_INSTALL_TWICE:-}" = "1" ]; then
      runs=2
    fi
    if [ "${E2E_GO_MIRROR:-}" = "1" ]; then
      [ "$language" = "go" ] || fail "E2E_GO_MIRROR is for Go"
      prepare_ddtest_mirror
      export INTAKE_MIRROR_AUTHORIZATION="Bearer e2e-mirror-token"
      start_intake
      export DD_SET_TRACER_REPOSITORY_URL_GO="$intake_url/mirror"
      export DD_SET_AUTH_HEADER_GO="Authorization: $INTAKE_MIRROR_AUTHORIZATION"
    fi
    for run in $(seq 1 "$runs"); do
      # The second run starts with the first one's output exported: for Go,
      # with ddtest's go first on PATH and the installed ddtest to replace.
      run_installer > "$E2E_DIR/$language-shell.env" || fail "installer run $run failed"
      while IFS='=' read -r name value; do
        if [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          export "$name=$value"
        fi
      done < "$E2E_DIR/$language-shell.env"
    done
    run_tests
    ;;
  skipped)
    [ "$language" = "go" ] || fail "skipped runs Go with a toolchain older than 1.25"
    new_project
    unset GITHUB_ACTION GITHUB_PATH GITHUB_ENV
    status=0
    run_installer > "$E2E_DIR/go-skipped.env" 2> "$E2E_DIR/go-skipped.err" || status=$?
    cat "$E2E_DIR/go-skipped.err" >&2
    [ "$status" -eq 0 ] || fail "the installer must let the job continue, exit status $status"
    grep -q '^Warning: The installed Go version' "$E2E_DIR/go-skipped.err" || fail "no warning about the Go version"
    grep -q '^Skipping Go instrumentation.' "$E2E_DIR/go-skipped.err" || fail "Go was not skipped"
    ! grep -qE '^(PATH|DD_TRACER_VERSION_GO)=' "$E2E_DIR/go-skipped.env" || fail "the installer printed Go settings"
    [ ! -e .datadog/ddtest ] || fail "the installer downloaded ddtest"
    go test -count=1 ./... >&2 || fail "the tests must still pass with plain go test"
    echo "PASS (go, skipped): $(go env GOVERSION) skipped with a warning; the tests ran without Test Optimization"
    ;;
  github-install)
    [ -n "${GITHUB_ENV:-}" ] || fail "github-install runs in a GitHub Actions step"
    new_project
    run_installer > "$E2E_DIR/$language-github.env"
    cat "$E2E_DIR/$language-github.env" >> "$GITHUB_ENV"
    ;;
  github-test|test)
    [ -d "$project" ] || fail "the project does not exist: $project"
    cd "$project"
    run_tests
    ;;
  prepare)
    # The workspace of a GitHub Actions job: write the project beside what is
    # already there.
    [ -n "${E2E_PROJECT:-}" ] || fail "prepare writes the project in E2E_PROJECT"
    mkdir -p "$project"
    cd "$project"
    prepare_project
    ;;
  patch-github-action)
    action_yml="${3:?$usage}/action.yml"
    [ -f "$action_yml" ] || fail "no action.yml in $3"
    # The action downloads the installer with curl, which reads file URLs.
    installer_url="file://$installer"
    if is_windows; then
      installer_url="file:///$(cygpath -m "$installer")"
    fi
    installer_sum="$(sha256_of "$installer")"
    sed -E -e "s|^( +INSTALLATION_SCRIPT_URL: ).*|\1$installer_url|" \
      -e "s|^( +INSTALLATION_SCRIPT_CHECKSUM: ).*|\1$installer_sum|" \
      "$action_yml" > "$action_yml.patched"
    mv "$action_yml.patched" "$action_yml"
    grep -Fq "INSTALLATION_SCRIPT_URL: $installer_url" "$action_yml" &&
      grep -Fq "INSTALLATION_SCRIPT_CHECKSUM: $installer_sum" "$action_yml" ||
      fail "could not point $action_yml at this installer"
    echo "The action in $3 installs $installer_url"
    ;;
  gitlab)
    [ -f "${E2E_GITLAB_SCRIPT:-}" ] || fail "E2E_GITLAB_SCRIPT must name the GitLab script's script.sh"
    new_project
    start_intake
    installer_sum="$(sha256_of "$installer")"
    gitlab_script="$E2E_DIR/$language-gitlab-script.sh"
    sed -E -e "s|^installation_script_url=.*|installation_script_url=\"$intake_url/install_test_visibility.sh\"|" \
      -e "s|^installation_script_checksum=.*|installation_script_checksum=\"$installer_sum\"|" \
      "$E2E_GITLAB_SCRIPT" > "$gitlab_script"
    grep -Fq "installation_script_url=\"$intake_url/install_test_visibility.sh\"" "$gitlab_script" &&
      grep -Fq "installation_script_checksum=\"$installer_sum\"" "$gitlab_script" ||
      fail "could not point the GitLab script at this installer"
    unset GITHUB_ACTION GITHUB_PATH GITHUB_ENV
    # As the script's README has a GitLab job do: source it into the job's
    # shell, which then runs the tests. GitLab runs a job's script with -e,
    # without -u.
    set +u
    # shellcheck disable=SC1090
    LANGUAGES="$language" API_KEY=dummy source "$gitlab_script"
    set -u
    run_tests
    ;;
  circleci)
    [ -f "${E2E_CIRCLECI_SCRIPT:-}" ] || fail "E2E_CIRCLECI_SCRIPT must name the orb's autoinstrument.sh"
    new_project
    start_intake
    unset GITHUB_ACTION GITHUB_PATH GITHUB_ENV
    BASH_ENV="$E2E_DIR/$language-circleci-bash-env"
    : > "$BASH_ENV"
    # The orb's command runs the script in a step of its own, with its
    # parameters in the environment and CircleCI's bash -eo pipefail.
    DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES="$language" \
      INSTALLATION_SCRIPT_URL="$intake_url/install_test_visibility.sh" \
      INSTALLATION_SCRIPT_CHECKSUM="$(sha256_of "$installer")" \
      BASH_ENV="$BASH_ENV" \
      bash -eo pipefail "$E2E_CIRCLECI_SCRIPT" || fail "the orb's script failed"
    # Every later CircleCI step starts by sourcing BASH_ENV.
    set +u
    # shellcheck disable=SC1090
    source "$BASH_ENV"
    set -u
    run_tests
    ;;
  *)
    fail "unknown mode"
    ;;
esac
