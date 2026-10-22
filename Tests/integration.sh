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
keychain_path="${TMPDIR:-/tmp}/kcrun-test-$$.keychain-db"
keychain_password="kcrun-test-keychain-password"
original_keychains=$(security list-keychains -d user | sed 's/^[[:space:]]*//; s/^"//; s/"$//')

cleanup() {
  set --
  while IFS= read -r keychain; do
    [ -n "$keychain" ] && set -- "$@" "$keychain"
  done <<EOF
$original_keychains
EOF
  if [ "$#" -gt 0 ]; then
    security list-keychains -d user -s "$@" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  rm -f "$marker" "$stdout_file" "$stderr_file"
}
trap cleanup EXIT HUP INT TERM

echo "test: checking help output"
"$binary" --help >"$stdout_file" 2>"$stderr_file"
grep -q '^Usage:' "$stdout_file"
grep -q -- '--env NAME=SERVICE' "$stdout_file"
test ! -s "$stderr_file"
"$binary" -h >"$stdout_file" 2>"$stderr_file"
grep -q '^Usage:' "$stdout_file"
test ! -s "$stderr_file"

echo "test: checking argument errors"
set +e
"$binary" --env >"$stdout_file" 2>"$stderr_file"
argument_status=$?
set -e
test "$argument_status" -eq 2
test ! -s "$stdout_file"
grep -q -- "--env requires a NAME=SERVICE mapping" "$stderr_file"
grep -q "kcrun --help" "$stderr_file"

set +e
"$binary" --env BAD-NAME=service -- /usr/bin/true >"$stdout_file" 2>"$stderr_file"
argument_status=$?
set -e
test "$argument_status" -eq 2
grep -q "invalid environment-variable name" "$stderr_file"

echo "test: creating temporary Keychain"
security create-keychain -p "$keychain_password" "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 3600 "$keychain_path"
set -- "$keychain_path"
while IFS= read -r keychain; do
  [ -n "$keychain" ] && set -- "$@" "$keychain"
done <<EOF
$original_keychains
EOF
security list-keychains -d user -s "$@"

echo "test: adding temporary Keychain items"
security add-generic-password -U -a "$account" -s "$service" -w "$secret" -T "$binary" "$keychain_path"
security add-generic-password -U -a "$account" -s "$second_service" -w "$second_secret" -T "$binary" "$keychain_path"

# The child confirms injection without printing the secret.
echo "test: checking multiple environment mappings"
"$binary" \
  --env KCRUN_TEST_SECRET="$service" \
  --env KCRUN_TEST_SECRET_TWO="$second_service" \
  -- /bin/sh -c \
  'test "$KCRUN_TEST_SECRET" = "$1" && test "$KCRUN_TEST_SECRET_TWO" = "$2" && printf "injection-ok\n"' \
  sh "$secret" "$second_secret" >"$stdout_file" 2>"$stderr_file"
test "$(cat "$stdout_file")" = "injection-ok"
test ! -s "$stderr_file"

# A failed lookup must not start the requested command, even if an earlier
# mapping resolved successfully.
echo "test: checking missing-item failure"
missing_service="$service-missing"
if "$binary" \
  --env KCRUN_TEST_SECRET="$service" \
  --env KCRUN_TEST_SECRET_TWO="$missing_service" \
  -- /usr/bin/touch "$marker" \
  >"$stdout_file" 2>"$stderr_file"; then
  echo "test: missing Keychain item unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$marker"
test ! -s "$stdout_file"
grep -q "no generic password found for Keychain service" "$stderr_file"

# The command's exit status must pass through kcrun.
echo "test: checking child exit status"
set +e
"$binary" --env KCRUN_TEST_SECRET="$service" -- /bin/sh -c 'exit 23' \
  >"$stdout_file" 2>"$stderr_file"
child_status=$?
set -e
test "$child_status" -eq 23

echo "test: checking command-not-found guidance"
set +e
"$binary" --env KCRUN_TEST_SECRET="$service" -- kcrun-command-that-does-not-exist \
  >"$stdout_file" 2>"$stderr_file"
child_status=$?
set -e
test "$child_status" -eq 127
test ! -s "$stdout_file"
grep -q "was not found" "$stderr_file"
grep -q "PATH" "$stderr_file"

echo "kcrun integration tests passed"
