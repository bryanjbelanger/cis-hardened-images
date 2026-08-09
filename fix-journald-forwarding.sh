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
DROPIN_DIR=/etc/systemd/journald.conf.d
DROPIN="$DROPIN_DIR/99-cis-forward-to-syslog.conf"

before=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
         | grep -E '^[[:space:]]*ForwardToSyslog' | tail -1)
log "effective before: ${before:-<unset>}"

# Show WHERE it is being set. Editing journald.conf was not enough because
# systemd gives *.conf.d drop-ins precedence over the main file — the earlier
# version of this script set the file correctly and the effective value stayed
# `yes`.
log "sources setting it:"
grep -rEl '^[[:space:]]*ForwardToSyslog' \
  /etc/systemd/journald.conf /etc/systemd/journald.conf.d/ \
  /usr/lib/systemd/journald.conf.d/ /run/systemd/journald.conf.d/ 2>/dev/null \
  | sed 's/^/  | /'

# Fix the main file for tidiness, then win on precedence with a drop-in in /etc,
# which outranks both the main file and any vendor drop-in under /usr/lib.
sed -i 's/^[[:space:]]*ForwardToSyslog[[:space:]]*=.*/ForwardToSyslog=no/' "$CONF" 2>/dev/null
install -d -m 0755 "$DROPIN_DIR"
printf '[Journal]\nForwardToSyslog=no\n' > "$DROPIN"
chmod 0644 "$DROPIN"
log "wrote $DROPIN"

systemctl restart systemd-journald >/dev/null 2>&1 || log "WARNING: journald restart failed"
sleep 2

# Verify the EFFECTIVE value, not the file. Checking the file is what let a
# published image ship ForwardToSyslog=yes while its audit claimed the rule
# passed.
after=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | grep -E '^[[:space:]]*ForwardToSyslog' | tail -1)
log "effective after:  ${after:-<unset>}"
case "$after" in
  *=no) log "OK — journald no longer forwards to syslog" ;;
  *)    log "WARNING: still not disabled; something outranks $DROPIN" ;;
esac
exit 0
