#!/usr/bin/env bash
# The readiness contract must run in the minimal validate-configs CI image.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO_ROOT"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
test_bin="$tmp_dir/bin"
output_file="$tmp_dir/readiness.log"
mkdir -p "$test_bin"

for required_command in bash dirname find git grep jq python3 sort awk; do
  command_path=$(command -v "$required_command")
  ln -s "$command_path" "$test_bin/$required_command"
done

if PATH="$test_bin" command -v rg >/dev/null; then
  echo "FAIL: the portability test PATH unexpectedly contains rg" >&2
  exit 1
fi

if ! PATH="$test_bin" bash tests/github/merge-queue-readiness.test.sh \
    >"$output_file" 2>&1; then
  cat "$output_file" >&2
  echo "FAIL: the readiness contract requires a tool outside the CI image" >&2
  exit 1
fi

grep -qF 'Results: 27/27 checks passed' "$output_file" || {
  cat "$output_file" >&2
  echo "FAIL: the readiness contract did not complete all checks" >&2
  exit 1
}

echo "PASS: merge-queue readiness runs without ripgrep"
