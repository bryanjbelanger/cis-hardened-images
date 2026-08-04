#!/usr/bin/env bash
# Exercise seal.sh + lock-accounts.sh EXACTLY as Packer runs them, against an
# already-built VM, in about two minutes instead of a 30-minute build cycle.
#
# WHY THIS EXISTS
# Five consecutive Packer builds died in the last mile — /var/lib/dbus missing,
# `dd` failing with ENOSPC by design, the AIDE config path differing on EL,
# /root unreadable by the SSH user, and the password change breaking Packer's
# own shutdown. Every one was reproducible in seconds; each instead cost a full
# build cycle because the scripts were only ever run inside Packer.
#
# The three things Packer does that hand-testing did not:
#   1. runs scripts with `bash -eux` (any non-zero command aborts)
#   2. connects as an UNPRIVILEGED user and escalates with `sudo -S`
#   3. downloads artifacts AS THAT USER (so /root paths are unreadable)
# This harness reproduces all three.
#
# Usage:
#   ./test-seal.sh <vm-name-or-vmx> <ip> [--no-lock]
#
# --no-lock stops before lock-accounts.sh, leaving the VM reusable. Without it
# the VM is sealed for real and cannot be re-tested (root gets locked).
set -uo pipefail
cd "$(dirname "$0")"

VM="${1:?usage: test-seal.sh <vm|vmx> <ip> [--no-lock]}"
IP="${2:?need the guest IP}"
NO_LOCK="${3:-}"
source local-creds.env

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o PreferredAuthentications=password -o ConnectTimeout=15)
fail=0

run_as_packer() {  # $1 = local script, mirrors Packer's execute_command
  local script=$1 name; name=$(basename "$script")
  echo "=== running $name as Packer does (bash -eux via sudo -S, unprivileged ssh) ==="
  expect -c "
    set timeout 1800
    spawn scp ${SSH_OPTS[*]} $script builder@$IP:/tmp/$name
    expect \"password:\" { send \"$PW_BUILDER\r\" }
    expect eof
  " >/dev/null 2>&1
  expect -c "
    set timeout 1800
    spawn ssh ${SSH_OPTS[*]} builder@$IP {echo PW | sudo -S bash -eux /tmp/$name}
    expect \"builder@\" { send \"$PW_BUILDER\r\" }
    expect \"password for builder\" { send \"$PW_BUILDER\r\" }
    expect eof
  " 2>&1 | sed "s/^/  [$name] /" | tail -40
}

echo "### 1. static checks"
for s in seal.sh lock-accounts.sh; do
  bash -n "$s" && echo "  ✓ $s parses" || { echo "  ✗ $s syntax"; fail=1; }
done
command -v shellcheck >/dev/null && shellcheck -S warning seal.sh lock-accounts.sh || echo "  (shellcheck not installed — skipping)"

echo "### 2. seal.sh under Packer conditions"
run_as_packer seal.sh

echo "### 3. artifact retrievable BY THE SSH USER (not root)"
# Packer's file provisioner downloads as `builder`; anything under /root fails.
if expect -c "
  set timeout 60
  spawn scp ${SSH_OPTS[*]} builder@$IP:/tmp/seal.log /tmp/seal-test.log
  expect \"password:\" { send \"$PW_BUILDER\r\" }
  expect eof" >/dev/null 2>&1 && [ -s /tmp/seal-test.log ]; then
  echo "  ✓ /tmp/seal.log downloaded as builder"
  echo "  --- seal log ---"; sed 's/^/    /' /tmp/seal-test.log
  if grep -q "AIDE BASELINE MISSING" /tmp/seal-test.log; then
    echo "  ✗ AIDE baseline missing — image would ship without integrity data"; fail=1
  elif grep -q "AIDE baseline OK" /tmp/seal-test.log; then
    echo "  ✓ AIDE baseline built"
  fi
else
  echo "  ✗ could not download the seal log as the SSH user"; fail=1
fi

if [ "$NO_LOCK" = "--no-lock" ]; then
  echo "### 4. skipped lock-accounts.sh (--no-lock): VM stays reusable"
else
  echo "### 4. lock-accounts.sh (IRREVERSIBLE — root gets locked)"
  run_as_packer lock-accounts.sh
fi

echo
[ "$fail" -eq 0 ] && echo "RESULT: chain is Packer-safe" || echo "RESULT: FAILURES ABOVE — fix before spending a build cycle"
exit $fail
