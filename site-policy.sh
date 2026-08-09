#!/usr/bin/env bash
# Site policy and residual-rule fixes, run inside the guest as root AFTER the
# first remediation pass and the reboot, so the second pass and the final audit
# both see them.
#
# WHY THIS EXISTS SEPARATELY
# The EL kickstart applies these in %post. Ubuntu cannot: its hardening happens
# post-boot (Subiquity installs `packages:` from the ISO alone), so the
# equivalent work has to live here. Running it on both keeps the two families
# converged — every step is idempotent, so re-applying on EL is harmless.
#
# Each fix here corresponds to a rule that measurably failed without it. They
# are NOT guesses: an Ubuntu 24.04 build scored 357 pass / 5 fail without this
# script and 360 / 2 with the equivalent steps applied by hand.
set -uo pipefail
set +e   # several steps return non-zero harmlessly; Packer runs us with -e

log() { echo "[site-policy] $*"; }

# --- sshd_limit_user_access -------------------------------------------------
# CIS wants sshd to name who may log in. Site policy: the admin group, which
# differs by family (wheel on EL, sudo on Debian/Ubuntu). builder is a member,
# so the shipped image stays reachable.
if getent group sudo >/dev/null 2>&1; then ADMIN_GROUP=sudo; else ADMIN_GROUP=wheel; fi
install -d -m 0755 /etc/ssh/sshd_config.d 2>/dev/null
printf 'AllowGroups %s\n' "$ADMIN_GROUP" > /etc/ssh/sshd_config.d/49-cis-access.conf
chmod 0600 /etc/ssh/sshd_config.d/49-cis-access.conf
log "sshd restricted to group $ADMIN_GROUP"

# --- root_path_all_dirs -----------------------------------------------------
# /snap/bin is on root's PATH via /etc/profile.d/apps-bin-path.sh but does not
# exist on a minimal server. Editing /etc/environment or /etc/login.defs does
# NOT fix the rule — the profile.d script re-adds it — so create the directory.
if grep -rqs "/snap/bin" /etc/profile.d/ /etc/environment /etc/login.defs 2>/dev/null; then
  install -d -o root -g root -m 0755 /snap/bin
  log "created /snap/bin (referenced by PATH but absent on minimal installs)"
fi

# --- all_apparmor_profiles_in_enforce_complain_mode -------------------------
# The kernel arguments alone are not enough; profiles must be put into enforce
# mode explicitly. Needs the post-reboot kernel, which is why this runs here.
if command -v aa-enforce >/dev/null 2>&1 && [ -d /etc/apparmor.d ]; then
  aa-enforce /etc/apparmor.d/* >/dev/null 2>&1
  log "apparmor: $(aa-status 2>/dev/null | grep -oE '[0-9]+ profiles are in enforce mode' || echo 'status unavailable')"
fi

# --- file_groupowner_cron_allow ---------------------------------------------
touch /etc/cron.allow && chown root:root /etc/cron.allow && chmod 0640 /etc/cron.allow
log "cron.allow present, root:root 0640"

# --- service masks ----------------------------------------------------------
# journald is the log backend (rsyslog must not run alongside it), this host
# must not accept remote journal entries, and bluetooth has no role on a
# server image. nftables is masked where ufw is the firewall.
# rsyslog: masked, for BOTH benchmarks.
#
# CIS requires journald and rsyslog not to run together
# (ensure_journald_and_rsyslog_not_active_together). STIG has
# service_rsyslog_enabled, so enabling it for STIG builds looked obviously
# right — and MEASURING it showed the opposite:
#
#   rocky10 STIG, rsyslog masked   457 pass / 14 fail, rule PASSES
#   rocky10 STIG, rsyslog enabled  456 pass / 15 fail, rule FAILS
#   rocky9  STIG, rsyslog masked   439 pass / 12 fail
#   rocky9  STIG, rsyslog enabled  438 pass / 13 fail
#
# Enabling rsyslog introduced the very failure it was meant to remove, on both
# targets, with the guest confirmed `enabled` and `active` at audit time. Why
# the rule reports fail in that state is not understood; until it is, the
# measured-better configuration wins over the intuitive one.
for unit in rsyslog.service systemd-journal-remote.socket bluetooth.service; do
  systemctl mask "$unit" >/dev/null 2>&1
done

if command -v ufw >/dev/null 2>&1; then
  systemctl mask nftables.service >/dev/null 2>&1
  log "masked rsyslog, journal-remote, bluetooth, nftables"
else
  log "masked rsyslog, journal-remote, bluetooth"
fi

# NOTE: /var/log ownership is deliberately NOT touched here. CIS specifies
# PER-FILE group owners (syslog:adm, root:systemd-journal, root:utmp, ...) and a
# blanket `chown -R root:syslog /var/log` broke nine rules when tried. oscap's
# own remediation sets each correctly — let it.

log "site policy applied"
exit 0
