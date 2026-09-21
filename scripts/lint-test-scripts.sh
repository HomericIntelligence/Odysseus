#!/bin/sh
# Validate exact staged Bash tests from any working directory.
set -u

case "$0" in
  /*) script_path=$0 ;;
  *) script_path=$PWD/$0 ;;
esac
script_directory=${script_path%/*}
if [ "$script_directory" = "$script_path" ]; then
  script_directory=.
fi
unset CDPATH
repo_root=$(command cd -P -- "$script_directory/.." && command pwd -P) || {
  printf 'error: could not bind repository directory\n' >&2
  exit 2
}
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
  /usr/bin/python3 -I -S "$repo_root/scripts/lint_test_scripts.py" \
  --repo-root "$repo_root" "$@"
