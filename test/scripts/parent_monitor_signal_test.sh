#!/usr/bin/env bash
#
# T54.5 (issue #1073) real signal-propagation test. ExUnit can inject a stub
# `on_dead` but cannot prove the OS-level chain the fix actually depends on:
#
#   launcher (killed)  ->  ParentMonitor halts the BEAM  ->  dispatch port closes
#   ->  ChildSupervisor watchdog reaps the child's whole process group.
#
# This drives the REAL ParentMonitor + REAL wrapper (via `mix run --no-start`),
# sends a REAL SIGTERM to a stand-in launcher, and asserts the child AND its
# grandchild actually die. Regression guard for the exact bug: killing the
# launcher used to leave `claude -p` running to natural completion, orphaned.
#
# Exit 0 = the tree was reaped. Non-zero (with a FAIL line) = the orphan survived.
set -euo pipefail

cd "$(dirname "$0")/../.."

tmp="$(mktemp -d)"
child_pidfile="$tmp/child.pid"
gc_pidfile="$tmp/gc.pid"
launcher=""
beam=""

cleanup() {
  for pid in "$launcher" "$beam" "$(cat "$child_pidfile" 2>/dev/null || true)" "$(cat "$gc_pidfile" 2>/dev/null || true)"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

# The stand-in launcher: a process we control, whose death is the #1073 trigger.
sleep 600 &
launcher=$!

LAUNCHER_PID="$launcher" CHILD_PIDFILE="$child_pidfile" GC_PIDFILE="$gc_pidfile" \
  mix run --no-start test/scripts/parent_monitor_signal.exs >/dev/null 2>&1 &
beam=$!

# Wait for the wrapped child AND its grandchild to come up.
for _ in $(seq 1 200); do
  [ -s "$child_pidfile" ] && [ -s "$gc_pidfile" ] && break
  sleep 0.1
done

child="$(cat "$child_pidfile" 2>/dev/null || true)"
gc="$(cat "$gc_pidfile" 2>/dev/null || true)"

if [ -z "$child" ] || [ -z "$gc" ]; then
  echo "FAIL: dispatch tree never came up (child='$child' grandchild='$gc')"
  exit 1
fi
if ! kill -0 "$child" 2>/dev/null || ! kill -0 "$gc" 2>/dev/null; then
  echo "FAIL: dispatch tree not alive before the launcher was killed"
  exit 1
fi

echo "dispatch tree up: child=$child grandchild=$gc; killing launcher=$launcher"

# The #1073 trigger: SIGTERM the LAUNCHER (not the BEAM, not the controller).
kill -TERM "$launcher"

# Assert BOTH the child and the grandchild are reaped within the window.
for _ in $(seq 1 100); do
  if ! kill -0 "$child" 2>/dev/null && ! kill -0 "$gc" 2>/dev/null; then
    echo "PASS: launcher death reaped the whole dispatch tree (child=$child grandchild=$gc)"
    exit 0
  fi
  sleep 0.1
done

echo "FAIL: dispatch tree survived the launcher's death (child=$child grandchild=$gc still alive)"
exit 1
