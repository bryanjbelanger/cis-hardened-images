#!/usr/bin/env bash
# The LAST root action before export. Split out from seal.sh deliberately:
# locking root kills MCP guest operations instantly, so anything that needs
# verifying must be verified BEFORE this runs. Do not merge these back together
# — that made a silently-failed AIDE baseline indistinguishable from success.
#
# Run only after seal.sh's log has been retrieved and checked.
set -u
echo "[lock] expiring builder password (forces change at first login)"
chage -d 0 builder 2>/dev/null
echo "[lock] locking root — guest operations stop working now"
passwd -l root >/dev/null 2>&1
