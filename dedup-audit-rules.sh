#!/usr/bin/env bash
# De-duplicate audit rules across /etc/audit/rules.d, then load them.
#
# WHY THIS EXISTS
# auditctl aborts the ENTIRE load on a duplicate rule:
#
#     Error sending add rule data request (Rule exists)
#     There was an error in line 17 of /etc/audit/audit.rules
#     No rules
#
# It is not a warning and it is not skipped — everything after that line is
# never loaded. On AlmaLinux 10 STIG this left 12 rules active out of 113 and
# failed 79 audit_rules_* checks (370 pass / 100 fail), while Rocky 10 from the
# same profile scored 457/14 because its content happens not to emit a
# duplicate.
#
# The rules were written correctly and `augenrules --check` reported "No change",
# so every layer looked healthy except the running kernel. Four hypotheses were
# tested before the load was replayed with its output kept: the failure message
# had been going into `augenrules --load | tail -3`, which discards exactly the
# line that names the problem.
#
# Dedup happens in rules.d, not in the compiled audit.rules, because augenrules
# regenerates audit.rules from rules.d at every boot — fixing the compiled file
# would survive exactly until the next reboot.
set -uo pipefail

log() { echo "[dedup-audit] $*"; }

[ -d /etc/audit/rules.d ] || { log "no rules.d — nothing to do"; exit 0; }

# ONLY act when the load is actually broken. Rocky 10 loads all 113 of its rules
# with duplicates present and scores 457/14; rewriting its rules.d would change a
# working system for no benefit, and rules relocating between files can break
# checks that look for a rule in a SPECIFIC file. So: try a load first, and leave
# a healthy system completely alone.
active_now=$(auditctl -l 2>/dev/null | wc -l | tr -d ' ')
if [ "$active_now" -ge 50 ]; then
  log "$active_now rules already active — healthy, leaving rules.d untouched"
  exit 0
fi
log "only $active_now rules active — checking for a duplicate abort"
if ! auditctl -R /etc/audit/audit.rules 2>&1 | grep -q 'Rule exists'; then
  log "no duplicate-rule abort detected — leaving rules.d untouched"
  exit 0
fi
log "duplicate rule aborts the load; de-duplicating"


before=$(cat /etc/audit/rules.d/*.rules 2>/dev/null | grep -cvE '^[[:space:]]*(#|$)')

# Walk the files in the SAME lexical order augenrules concatenates them, keeping
# the first occurrence of each rule and dropping later repeats. Comments and
# blank lines are preserved so the files stay readable.
python3 - <<'PYEOF'
import glob
seen = set()
removed = 0
for path in sorted(glob.glob('/etc/audit/rules.d/*.rules')):
    out, changed = [], False
    for line in open(path):
        s = line.strip()
        if not s or s.startswith('#'):
            out.append(line)
            continue
        if s in seen:
            removed += 1
            changed = True
            continue
        seen.add(s)
        out.append(line)
    if changed:
        open(path, 'w').writelines(out)
print(f"[dedup-audit] removed {removed} duplicate rule line(s)")
PYEOF

after=$(cat /etc/audit/rules.d/*.rules 2>/dev/null | grep -cvE '^[[:space:]]*(#|$)')
log "rule lines: $before -> $after"

# Recompile and load. Keep the FULL output: this is the step whose message was
# being thrown away.
log "loading"
augenrules --load 2>&1 | head -20 | sed 's/^/  | /'

active=$(auditctl -l 2>/dev/null | wc -l | tr -d ' ')
log "active rules now: $active"

# Verify against the kernel, not against exit codes. A load that silently
# applied 12 of 113 rules is the failure this script exists to prevent.
if [ "$active" -lt 20 ]; then
  log "WARNING: only $active rules active — the load is still failing"
  log "  replaying to surface the rejection:"
  auditctl -R /etc/audit/audit.rules 2>&1 | head -10 | sed 's/^/  | /'
fi
exit 0
