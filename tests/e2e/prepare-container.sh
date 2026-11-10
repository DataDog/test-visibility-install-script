#!/bin/sh
# Install what tests/e2e/run.sh needs in a CI container image, such as the
# images of GitLab jobs: Bash, which the wrappers and the harness run in, and
# Python, for the intake. The image's own tools stay as they are, so Alpine
# keeps BusyBox's wget and sha256sum.

set -eu

missing=""
command -v bash >/dev/null 2>&1 || missing="$missing bash"
command -v python3 >/dev/null 2>&1 || missing="$missing python3"
[ -n "$missing" ] || exit 0

if command -v apk >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  apk add --no-cache $missing
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing
else
  echo "Cannot install:$missing" >&2
  exit 1
fi
