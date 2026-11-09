#!/usr/bin/env bash
# End-to-end test of the installer for one language, with the real libraries.
#
#   tests/e2e/run.sh <language> shell
#   tests/e2e/run.sh <language> github-install   (in a GitHub Actions step)
#   tests/e2e/run.sh <language> github-test      (in a later step of that job)
#
# Each run builds a small project with one passing test for the language, runs
# the installer from the project, runs the project's tests with what the
# installer configured, and checks that the test's event, found by the
# test's name (DdE2eMarker), reached a local stand-in for Datadog's intake
# (tests/e2e/intake.py). No backend or real API key is needed.
#
# shell consumes the installer's output as the README shows, the way the
# GitLab script and the CircleCI orb do: it exports every printed variable in
# the same shell, outside GitHub Actions. github-install consumes it as the
# GitHub action does, appending it to GITHUB_ENV, and github-test then runs the
# tests in the job's next step, which also gets what the installer added to
# GITHUB_PATH.
#
# Languages: go, python, js, java, dotnet, ruby. The runner needs the
# language's toolchain: Go 1.25 or newer, Python with venv, Node.js with npm,
# a JDK with Maven, the .NET SDK, or Ruby with Bundler. E2E_DIR (default
# $RUNNER_TEMP/dd-e2e, else a new temporary directory) holds the projects.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="${INSTALLER_UNDER_TEST:-$repo_root/install_test_visibility.sh}"
language="${1:?usage: run.sh <language> shell|github-install|github-test}"
mode="${2:?usage: run.sh <language> shell|github-install|github-test}"

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
project="$E2E_DIR/$language-$mode"
if [ "$mode" = "github-test" ]; then
  project="$E2E_DIR/$language-github-install"
fi

is_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# The settings that every run uses: delivery goes to the local intake, which
# run_tests starts, with a placeholder API key.
export DD_API_KEY=dummy
export DD_SERVICE="install-script-e2e-$language"
export DD_CIVISIBILITY_GIT_UPLOAD_ENABLED=false
export DD_INSTRUMENTATION_TELEMETRY_ENABLED=false
export DD_REMOTE_CONFIGURATION_ENABLED=false

# An older go directive than ddtest's own toolchain requirement: the Go project
# keeps its language version, and the installer must not change the file.
go_mod="$(printf 'module example.com/e2e\n\ngo 1.22')"

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
      printf '%s\n' "$go_mod" > go.mod
      cat > e2e_test.go <<'GO'
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
    go) go test -count=1 ./... ;;
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

# Start the intake, run the tests and check that their events arrived.
run_tests() {
  local intake_dir="$E2E_DIR/intake-$language-$mode"
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
  # holds them keeps the GitHub Actions step running.
  "$python_bin" "$repo_root/tests/e2e/intake.py" "$intake_dir/port" "$intake_dir/requests.log" \
    > "$intake_dir/intake.out" 2>&1 &
  local intake_pid=$!
  # shellcheck disable=SC2064
  trap "kill $intake_pid 2>/dev/null || true" EXIT
  local _
  for _ in $(seq 1 100); do
    [ -s "$intake_dir/port" ] && break
    sleep 0.1
  done
  [ -s "$intake_dir/port" ] || fail "the intake did not start"
  DD_CIVISIBILITY_AGENTLESS_URL="http://127.0.0.1:$(cat "$intake_dir/port")"
  export DD_CIVISIBILITY_AGENTLESS_URL

  if [ "$language" = "python" ]; then
    activate_python_venv
  fi
  local test_log="$intake_dir/tests.log"
  if ! project_tests > "$test_log" 2>&1; then
    cat "$test_log" >&2
    fail "the project's tests failed with the installer's environment"
  fi

  # The test's own event names it; a session or module event does not.
  if ! grep -a -q 'DdE2eMarker' "$intake_dir/requests.log.payloads" 2>/dev/null; then
    cat "$test_log" >&2
    echo "--- requests that reached the intake:" >&2
    cat "$intake_dir/requests.log" >&2 2>/dev/null || echo "(none)" >&2
    fail "the test's event did not reach the intake"
  fi

  if [ "$language" = "go" ]; then
    # go test keeps its own exit status through ddtest's go.
    if E2E_FAIL=1 go test -count=1 ./... > "$test_log" 2>&1; then
      cat "$test_log" >&2
      fail "a failing Go test must fail go test"
    fi
    [ "$(cat go.mod)" = "$go_mod" ] || fail "go.mod changed"
    # The installer's own folder aside, the project keeps only its files.
    local files=()
    local file
    for file in * .[!.]*; do
      if [ -e "$file" ] && [ "$file" != ".datadog" ]; then
        files+=("$file")
      fi
    done
    [ "${files[*]}" = "e2e_test.go go.mod" ] || fail "the project's files changed: ${files[*]}"
  fi

  kill "$intake_pid" 2>/dev/null || true
  trap - EXIT
  echo "PASS ($language, $mode): the test's event reached the intake"
}

run_installer() {
  DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES="$language" bash "$installer"
}

case "$mode" in
  shell)
    rm -rf "$project"
    mkdir -p "$project"
    cd "$project"
    prepare_project
    # Outside GitHub Actions, even when this test runs there.
    unset GITHUB_ACTION GITHUB_PATH GITHUB_ENV
    run_installer > "$E2E_DIR/$language-shell.env"
    while IFS='=' read -r name value; do
      if [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        export "$name=$value"
      fi
    done < "$E2E_DIR/$language-shell.env"
    run_tests
    ;;
  github-install)
    [ -n "${GITHUB_ENV:-}" ] || fail "github-install runs in a GitHub Actions step"
    rm -rf "$project"
    mkdir -p "$project"
    cd "$project"
    prepare_project
    run_installer > "$E2E_DIR/$language-github.env"
    cat "$E2E_DIR/$language-github.env" >> "$GITHUB_ENV"
    ;;
  github-test)
    [ -d "$project" ] || fail "github-install did not run"
    cd "$project"
    run_tests
    ;;
  *)
    fail "unknown mode"
    ;;
esac
