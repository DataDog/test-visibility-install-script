#!/usr/bin/env bash
# Real-network smoke test for the Python installation path.
#
# Unlike tests/run_python_matrix.sh (deterministic, fake python/pip), this test
# creates a real virtual environment and lets the installer talk to PyPI. It
# proves that ddtrace instruments pytest with NO coverage package installed in
# the environment, which is exactly what the removal of the forced coverage
# installation needs to keep holding.
#
# No backend or real API key is needed: instrumentation traffic is directed at
# a closed local port.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${INSTALLER_UNDER_TEST:-$repo_root/install_test_visibility.sh}"
python_bin="${1:-python}"

case_root="$(mktemp -d "${TMPDIR:-/tmp}/dd-python-smoke.XXXXXX")"
trap 'rm -rf "$case_root"' EXIT
cd "$case_root"

"$python_bin" -m venv app
# shellcheck disable=SC1091
source app/bin/activate

python -m pip install 'pytest==8.4.2' >&2

export DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES=python
# Keep instrumentation active while directing traffic to a closed local port.
export DD_API_KEY=dummy
export DD_CIVISIBILITY_AGENTLESS_URL=http://127.0.0.1:9
export DD_CIVISIBILITY_ITR_ENABLED=false
export DD_INSTRUMENTATION_TELEMETRY_ENABLED=false
export DD_REMOTE_CONFIGURATION_ENABLED=false

bash "$installer" > installer.env

# Export every environment variable printed by the installer.
while IFS='=' read -r name value; do
  export "$name=$value"
done < installer.env

python - <<'PY'
import os
import sys
from importlib.metadata import PackageNotFoundError, version

ddtrace_version = version("ddtrace")

try:
    version("coverage")
    raise SystemExit(
        "Error: the installer must not install the coverage package "
        "(found coverage " + version("coverage") + ")"
    )
except PackageNotFoundError:
    pass

assert os.environ["DD_TRACER_VERSION_PYTHON"] == ddtrace_version, (
    os.environ["DD_TRACER_VERSION_PYTHON"],
    ddtrace_version,
)
assert os.environ["DD_CIVISIBILITY_ENABLED"] == "true"
assert os.environ["DD_CIVISIBILITY_AGENTLESS_ENABLED"] == "true"
assert "--ddtrace" in os.environ["PYTEST_ADDOPTS"]
assert os.environ["PYTHONPATH"], "PYTHONPATH must point at the installed ddtrace"

print(
    "Python",
    sys.version.split()[0],
    "| ddtrace",
    ddtrace_version,
    "| coverage not installed (ok)",
)
PY

cat > example.py <<'PY'
def classify(value):
    if value > 0:
        return 'positive'
    return 'nonpositive'
PY

cat > test_example.py <<'PY'
from example import classify


def test_ddtrace_plugin_active(pytestconfig):
    assert pytestconfig.pluginmanager.hasplugin('ddtrace')


def test_positive():
    assert classify(1) == 'positive'


def test_nonpositive():
    assert classify(0) == 'nonpositive'
PY

# Run pytest through the installer-emitted PYTEST_ADDOPTS so the ddtrace
# plugin is active while no coverage package exists in the environment.
python -m pytest -q

# Double-check that no coverage executable became importable either.
if python -c 'import coverage' 2>/dev/null; then
  echo 'Error: coverage is importable; the smoke environment is not clean' >&2
  exit 1
fi

echo "Python smoke test passed on $(python -c 'import sys; print(sys.version.split()[0])')"
