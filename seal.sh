#!/usr/bin/env bash
# Seal a built + audited image for distribution. Runs INSIDE the guest as root
# (copied in and executed via MCP guest ops), immediately before export.
#
# ORDER MATTERS. `passwd -l root` is last because it is one-way: once root is
# locked, MCP guest operations stop working and nothing else can be fixed.
#
# Run this only after the final audit — every change here alters the system,
# and the AIDE baseline must describe the shipped state, not an earlier one.
set -u

log() { echo "[seal] $*"; }

# ---------------------------------------------------------------- build residue
# These contain the build password in plaintext. They are not secrets by policy
# (public images, root gets locked below), but they are noise no recipient wants.
log "shredding build residue"
for f in /root/anaconda-ks.cfg /root/original-ks.cfg /root/ks-post.log \
         /root/ks-remediation-report.html /root/remediation*.html \
         /root/p[0-9]*.log /root/p[0-9]*.done /root/audit*.txt /root/final*.txt \
         /root/*.txt; do
  [ -f "$f" ] && shred -u "$f" 2>/dev/null || rm -f "$f" 2>/dev/null
done
rm -rf /var/log/installer-failed /var/log/installer-syslog /var/crash/* 2>/dev/null
rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null

# ------------------------------------------------------------------ machine-id
# Every VM cloned from this image would otherwise share one machine ID, which
# collides DHCP DUIDs, journal identity, and anything else keyed on it.
# Truncate (do NOT delete): systemd regenerates on first boot only if the file
# exists and is empty.
log "clearing machine-id"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id 2>/dev/null
ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null

# --------------------------------------------------------------- ssh host keys
# Shipping host keys would make every deployment of this image present the same
# identity — mutually impersonable, and host-key verification becomes worthless.
# Both distro families regenerate missing keys at sshd start / first boot.
log "removing ssh host keys (regenerated on first boot)"
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub 2>/dev/null
systemctl enable ssh-keygen.service 2>/dev/null || true   # Ubuntu
systemctl enable sshd-keygen.target 2>/dev/null || true   # EL

# ------------------------------------------------------------------- log reset
log "truncating logs and login records"
: > /var/log/wtmp 2>/dev/null
: > /var/log/btmp 2>/dev/null
: > /var/log/lastlog 2>/dev/null
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
journalctl --rotate --vacuum-time=1s >/dev/null 2>&1 || true

# ------------------------------------------------------------- AIDE (CIS 6.1.x)
# Built LAST so the integrity baseline describes the sealed system. Anything
# changed after this point will legitimately show as tampering.
log "initializing AIDE baseline (this takes a few minutes)"
if command -v aideinit >/dev/null 2>&1; then
  aideinit -y -f >/dev/null 2>&1                       # Ubuntu wrapper
elif command -v aide >/dev/null 2>&1; then
  aide --init >/dev/null 2>&1
  for db in /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.new; do
    [ -f "$db" ] && mv -f "$db" "${db/.new/}"
  done
fi
log "AIDE baseline: $(ls -1 /var/lib/aide/aide.db* 2>/dev/null | tr '\n' ' ')"

# ------------------------------------------------------------- free-space zero
# THE size lever. ovftool compresses the disk, but unallocated blocks still hold
# deleted-file garbage that compresses badly: a measured export was 2.85 GB
# raw and 2.81 GB at --compress=9 — i.e. compression alone bought ~1%, and both
# blew GitHub's 2 GiB release-asset limit. Zeroing free space first lets those
# blocks collapse.
#
# Every mounted filesystem needs it, not just / — the CIS layout puts /home,
# /tmp, /var, /var/tmp, /var/log and /var/log/audit on separate volumes.
log "zeroing free space on each filesystem (slow; this is what makes the OVA shippable)"
for mp in $(findmnt -rno TARGET -t ext4,xfs 2>/dev/null); do
  case "$mp" in
    /proc*|/sys*|/dev*|/run*) continue ;;
  esac
  log "  zeroing $mp"
  dd if=/dev/zero of="${mp}/.zerofill" bs=1M status=none 2>/dev/null
  sync
  rm -f "${mp}/.zerofill"
  sync
done
# fstrim helps on thin-provisioned/SSD-backed disks where discard is supported.
fstrim -av >/dev/null 2>&1 || true

# ---------------------------------------------------------------- account state
# NOTE: locking accounts is deliberately NOT done here. Doing it in the same
# script made the seal unverifiable: root ops die instantly, so the log above
# can never be retrieved and a silently-failed AIDE build looks identical to a
# successful one. The pipeline must instead:
#   1. run this script,
#   2. copy /root/seal.log back to the host and CHECK IT (esp. the AIDE line),
#   3. only then run lock-accounts.sh as the final root action.
log "PRE-LOCK SEAL COMPLETE — verify this log, then run lock-accounts.sh"
