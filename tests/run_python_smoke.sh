#!/usr/bin/env bash
# Run on the active Python interpreter; no backend or real API key is needed.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_bin="${1:-python}"
installer="${INSTALLER_UNDER_TEST:-$repo_root/install_test_visibility.sh}"
case_root="$(mktemp -d "${TMPDIR:-/tmp}/dd-python-smoke.XXXXXX")"
trap 'rm -rf "$case_root"' EXIT
cd "$case_root"
"$python_bin" -m venv app
source app/bin/activate
python -m pip install 'pytest==8.4.2' >&2
export DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=python
export DD_SET_TRACER_VERSION_PYTHON=4.15.2
export DD_DEFAULT_COVERAGE_VERSION_PYTHON=7.16.1
# Keep instrumentation active while directing traffic to a closed local port.
export DD_API_KEY=dummy
export DD_CIVISIBILITY_AGENTLESS_URL=http://127.0.0.1:9
export DD_CIVISIBILITY_ITR_ENABLED=false
export DD_INSTRUMENTATION_TELEMETRY_ENABLED=false
export DD_REMOTE_CONFIGURATION_ENABLED=false
bash "$installer" > installer.env
while IFS='=' read -r name value; do
  export "$name=$value"
done < installer.env
python - <<'PY'
import os, sys
from importlib.metadata import version
expected = '7.10.7' if sys.version_info[:2] == (3, 9) else '7.16.1'
assert version('ddtrace') == '4.15.2'
assert version('coverage') == expected
assert os.environ['DD_COVERAGE_VERSION_PYTHON'] == expected
assert os.environ['DD_CIVISIBILITY_ENABLED'] == 'true'
print('Python', sys.version.split()[0], 'ddtrace', version('ddtrace'), 'coverage', version('coverage'))
PY
cat > example.py <<'PY'
def classify(value):
    if value > 0:
        return 'positive'
    return 'nonpositive'
PY
cat > test_example.py <<'PY'
from example import classify
from ddtrace.testing.internal.pytest.plugin import TestOptPlugin


def test_positive(pytestconfig):
    assert pytestconfig.pluginmanager.hasplugin('ddtrace')
    assert any(isinstance(plugin, TestOptPlugin) for plugin in pytestconfig.pluginmanager.get_plugins())
    assert classify(1) == 'positive'


def test_nonpositive():
    assert classify(0) == 'nonpositive'
PY
cat > .coveragerc <<'CFG'
[run]
branch = true
source = example
CFG
python -m coverage run -m pytest -q
python -m coverage report --fail-under=100
# Incompatible explicit overrides must fail and emit no instrumentation envs.
if [[ "$(python -c 'import sys; print(sys.version_info.minor)')" == 9 ]]; then
  export DD_SET_COVERAGE_VERSION_PYTHON=7.16.1
  if bash "$installer" > failed.env 2> failed.log; then
    echo 'Expected incompatible explicit coverage override to fail' >&2
    exit 1
  fi
  test ! -s failed.env
  grep -F 'Could not install coverage==7.16.1 for Python 3.9.' failed.log
  if grep -Fq 'Could not install ddtrace' failed.log; then exit 1; fi
  export DD_SET_COVERAGE_VERSION_PYTHON=7.10.6
  bash "$installer" > override.env
  while IFS='=' read -r name value; do
    export "$name=$value"
  done < override.env
  python -c 'import os; from importlib.metadata import version; assert version("coverage") == os.environ["DD_COVERAGE_VERSION_PYTHON"] == "7.10.6"'
  python -m coverage run -m pytest -q
  python -m coverage report --fail-under=100
fi
