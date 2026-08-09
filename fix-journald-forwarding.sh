#!/usr/bin/env bash
# Turn off journald's syslog forwarding, AFTER the final remediation pass.
#
# WHY IT RUNS HERE AND NOT IN site-policy.sh
# Ubuntu ships /etc/systemd/journald.conf with ForwardToSyslog=yes ACTIVE (above
# the commented default), and rsyslog is masked by site policy, so journald is
# forwarding to a daemon that is not running — which CIS flags via
# journald_disable_forward_to_syslog.
#
# The same change was first made in site-policy.sh and did nothing: site policy
# runs BEFORE the second remediation pass, and something in that pass puts the
# value back. The script logged success and the rule still failed. Ordering was
# the whole problem, so this runs after remediation and before the audit.
#
# WHY IT WAS MISSED FOR SO LONG
# oscap checks journald's RUNNING configuration. Before the audit ran after a
# reboot, journald had not reloaded its file since remediation, so the audit
# passed this rule while the shipped image violated it — confirmed by booting a
# published image, whose journald.conf had said `yes` since build time.
set -uo pipefail

log() { echo "[journald-fix] $*"; }

CONF=/etc/systemd/journald.conf
[ -f "$CONF" ] || { log "no $CONF — nothing to do"; exit 0; }

before=$(grep -E '^[[:space:]]*ForwardToSyslog' "$CONF" 2>/dev/null | head -1)
log "before: ${before:-<unset, using compiled default>}"

# Replace any active setting, and add one if the file only carries the commented
# default.
sed -i 's/^[[:space:]]*ForwardToSyslog[[:space:]]*=.*/ForwardToSyslog=no/' "$CONF"
grep -q '^ForwardToSyslog=no' "$CONF" || printf 'ForwardToSyslog=no\n' >> "$CONF"

# journald must reload, or the running config keeps the old value and the audit
# reads THAT — the exact trap this whole issue turned on.
systemctl restart systemd-journald >/dev/null 2>&1 || log "WARNING: journald restart failed"
sleep 2

after=$(grep -E '^[[:space:]]*ForwardToSyslog' "$CONF" | head -1)
log "after:  ${after:-<missing>}"

# Verify against the RUNNING daemon, not the file — checking the file would
# repeat the mistake that hid this.
running=$(systemctl show systemd-journald -p ForwardToSyslog --value 2>/dev/null)
if [ -n "$running" ]; then
  log "running daemon reports ForwardToSyslog=$running"
else
  eff=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^[[:space:]]*ForwardToSyslog' | tail -1)
  log "effective config: ${eff:-unavailable}"
fi
exit 0
