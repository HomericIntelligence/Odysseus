#!/usr/bin/env bash
# Enter only the cgroup subtree delegated to this transient CI service.
set -euo pipefail

if [ "$(id -u)" -eq 0 ] || [ "$#" -eq 0 ]; then
    echo 'error: delegated tests require an unprivileged user and a command' >&2
    exit 1
fi
case "${ODYSSEUS_CGROUP_ROOT:-}" in
    /sys/fs/cgroup/system.slice/odysseus-ci-unit-*.service) ;;
    *) echo 'error: unexpected CI delegation root' >&2; exit 1 ;;
esac
IFS= read -r membership < /proc/self/cgroup
expected="0::${ODYSSEUS_CGROUP_ROOT#/sys/fs/cgroup}/supervisor"
if [ "$membership" != "$expected" ]; then
    echo 'error: test process is outside its delegated supervisor subgroup' >&2
    exit 1
fi
# The service root is empty because systemd placed us in DelegateSubgroup.
# No ancestor or host-wide controller configuration is changed here.
printf '+cpu +memory +pids\n' > "$ODYSSEUS_CGROUP_ROOT/cgroup.subtree_control"
for controller in cpu memory pids; do
    if ! grep -qw "$controller" "$ODYSSEUS_CGROUP_ROOT/cgroup.subtree_control"; then
        echo "error: required controller was not delegated: $controller" >&2
        exit 1
    fi
done
exec "$@"
