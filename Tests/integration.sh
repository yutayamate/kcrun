#!/bin/sh
set -eu

binary=${1:-dist/kcrun}
if [ ! -x "$binary" ]; then
  echo "test: executable not found: $binary" >&2
  exit 2
fi

service="kcrun-test-$$-$(date +%s)"
second_service="${service}-second"
account="kcrun-test"
secret="kcrun-integration-test-secret"
second_secret="kcrun-second-integration-test-secret"
marker="${TMPDIR:-/tmp}/kcrun-test-marker-$$"
stdout_file="${TMPDIR:-/tmp}/kcrun-test-stdout-$$"
stderr_file="${TMPDIR:-/tmp}/kcrun-test-stderr-$$"

cleanup() {
  security delete-generic-password -a "$account" -s "$service" >/dev/null 2>&1 || true
  security delete-generic-password -a "$account" -s "$second_service" >/dev/null 2>&1 || true
  rm -f "$marker" "$stdout_file" "$stderr_file"
}
trap cleanup EXIT HUP INT TERM

security add-generic-password -U -a "$account" -s "$service" -w "$secret" -T "$binary"
security add-generic-password -U -a "$account" -s "$second_service" -w "$second_secret" -T "$binary"

# The child confirms injection without printing the secret.
"$binary" \
  --env KCRUN_TEST_SECRET="$service" \
  --env KCRUN_TEST_SECRET_TWO="$second_service" \
  -- /bin/sh -c \
  'test "$KCRUN_TEST_SECRET" = "$1" && test "$KCRUN_TEST_SECRET_TWO" = "$2" && printf "injection-ok\n"' \
  sh "$secret" "$second_secret" >"$stdout_file" 2>"$stderr_file"
test "$(cat "$stdout_file")" = "injection-ok"
test ! -s "$stderr_file"

# A failed lookup must not start the requested command.
missing_service="$service-missing"
if "$binary" --env KCRUN_TEST_SECRET="$missing_service" -- /usr/bin/touch "$marker" \
  >"$stdout_file" 2>"$stderr_file"; then
  echo "test: missing Keychain item unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$marker"
test ! -s "$stdout_file"
grep -q "no Keychain item found" "$stderr_file"

# The command's exit status must pass through kcrun.
set +e
"$binary" --env KCRUN_TEST_SECRET="$service" -- /bin/sh -c 'exit 23' \
  >"$stdout_file" 2>"$stderr_file"
child_status=$?
set -e
test "$child_status" -eq 23

echo "kcrun integration tests passed"
