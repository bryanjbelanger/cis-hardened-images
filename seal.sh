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
# Deliberately NOT `set -e`: several steps here fail by design (dd filling a
# filesystem, shred on absent files) and callers differ — Packer runs scripts
# with `bash -eux`, the MCP path with plain `bash`. Every command that matters
# is checked explicitly instead.
set +e

# The seal log is the artifact the pipeline VERIFIES before locking accounts,
# so it must be retrievable by the unprivileged build user: /root is 0700 and
# Packer's file provisioner downloads as the SSH user, not root. Write it to
# /tmp with world-read, and still echo to stdout for the MCP flow.
SEAL_LOG=${SEAL_LOG:-/tmp/seal.log}
: > "$SEAL_LOG" 2>/dev/null || true
chmod 0644 "$SEAL_LOG" 2>/dev/null || true
log() { echo "[seal] $*" | tee -a "$SEAL_LOG"; }

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
# The dbus compat symlink only applies where /var/lib/dbus exists. It does NOT
# on minimal Rocky 9 (modern dbus reads /etc/machine-id directly), and `ln` into
# a missing directory fails — which aborts the whole seal when the script is run
# under `bash -e`, as Packer does. The MCP path used a looser invocation and
# silently sailed past this.
if [ -d /var/lib/dbus ]; then
  rm -f /var/lib/dbus/machine-id
  ln -sf /etc/machine-id /var/lib/dbus/machine-id
fi

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
# Deliberately NOT `aideinit`: Ubuntu's wrapper hardcodes a log path under
# /var/log/aide and drops to the _aide user, which forces that directory to be
# _aide-owned — in direct conflict with CIS's root:syslog requirement for
# everything under /var/log. Satisfying one broke the other, repeatedly.
# `aide --init` as root produces the same database in /var/lib/aide and never
# touches /var/log. Verified on Ubuntu 24.04.
if command -v aide >/dev/null 2>&1; then
  # Config path differs by family: EL ships /etc/aide.conf, Debian/Ubuntu ship
  # /etc/aide/aide.conf. Hardcoding the Ubuntu path made aide exit 18
  # ("error in configuration") on Rocky 9 and produce NO baseline — caught only
  # because the seal log is verified before accounts are locked.
  AIDE_CONF=""
  for c in /etc/aide.conf /etc/aide/aide.conf; do
    [ -f "$c" ] && { AIDE_CONF="$c"; break; }
  done
  rc=0
  if [ -n "$AIDE_CONF" ]; then
    log "using aide config $AIDE_CONF"
    aide --config="$AIDE_CONF" --init > /root/aide-init.log 2>&1 || rc=$?
  else
    rc=127; log "WARNING: no aide config found"
  fi
  for db in /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.new; do
    [ -s "$db" ] && mv -f "$db" "${db/.new/}"
  done
  log "aide --init exit=$rc"
else
  log "WARNING: aide not installed — no integrity baseline"
fi
AIDE_DB=""
for d in /var/lib/aide/aide.db.gz /var/lib/aide/aide.db; do
  [ -s "$d" ] && { AIDE_DB="$d"; break; }
done
if [ -n "$AIDE_DB" ]; then
  log "AIDE baseline OK: $AIDE_DB ($(ls -l "$AIDE_DB" | awk '{print $5}') bytes)"
else
  log "AIDE BASELINE MISSING — do NOT ship this image (aide exit=$rc)"
fi

# ------------------------------------------------------------ image provenance
# /etc/cis-image-release answers "what am I, and what was I hardened against?"
# from INSIDE a running VM, with no reference to where it was downloaded from.
# Modelled on /etc/os-release. The build passes CIS_PROFILE / SSG_DS / AUDIT_*
# in the environment; everything else is discovered locally.
log "writing /etc/cis-image-release"
# The audit step wrote its summary in the guest; read the counts from there
# rather than threading them through the environment.
_audit_pass="unknown"; _audit_fail="unknown"
if [ -f /tmp/audit-summary.txt ]; then
  _audit_pass=$(grep -oE '^pass=[0-9]+' /tmp/audit-summary.txt | cut -d= -f2)
  _audit_fail=$(grep -oE '^fail=[0-9]+' /tmp/audit-summary.txt | cut -d= -f2)
fi
_ssg_version="unknown"
if command -v rpm >/dev/null 2>&1; then
  _ssg_version=$(rpm -q --qf '%{VERSION}-%{RELEASE}' scap-security-guide 2>/dev/null || echo unknown)
elif command -v dpkg-query >/dev/null 2>&1; then
  _ssg_version=$(dpkg-query -W -f='${Version}' ssg-debderived 2>/dev/null || echo staged)
fi
# The profile's own title carries the benchmark name and version, e.g.
# "CIS Red Hat Enterprise Linux 9 Benchmark for Level 1 - Server".
_benchmark="unknown"
if command -v oscap >/dev/null 2>&1 && [ -n "${SSG_DS:-}" ]; then
  _benchmark=$(oscap info "/usr/share/xml/scap/ssg/content/${SSG_DS}" 2>/dev/null \
    | grep -B1 -F "${CIS_PROFILE:-}" | grep -i "^\s*Title:" | head -1 \
    | sed 's/^[[:space:]]*Title:[[:space:]]*//' || echo unknown)
fi
. /etc/os-release 2>/dev/null || true
cat > /etc/cis-image-release <<PROVENANCE
IMAGE_NAME="CIS-hardened ${PRETTY_NAME:-unknown}"
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HYPERVISOR="${IMAGE_HYPERVISOR:-unknown}"
FIPS_MODE="$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)"
SCAP_PROFILE="${CIS_PROFILE:-unknown}"
SCAP_DATASTREAM="${SSG_DS:-unknown}"
SCAP_CONTENT_VERSION="${_ssg_version}"
BENCHMARK="${_benchmark:-unknown}"
AUDIT_PASS="${_audit_pass:-unknown}"
AUDIT_FAIL="${_audit_fail:-unknown}"
AUDIT_NOTES="Known exceptions are documented at the project README."
PROJECT_URL="https://github.com/bryanjbelanger/cis-hardened-images"
PROVENANCE
chmod 0644 /etc/cis-image-release
# Copy somewhere the unprivileged build user can retrieve it for the manifest.
cp /etc/cis-image-release /tmp/cis-image-release 2>/dev/null || true
chmod 0644 /tmp/cis-image-release 2>/dev/null || true
log "provenance: $(grep -c . /etc/cis-image-release) fields"

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
  # dd MUST fail here with ENOSPC — filling the filesystem is the entire point.
  # Without `|| true` this aborts the seal when run under `bash -e` (Packer).
  dd if=/dev/zero of="${mp}/.zerofill" bs=1M status=none 2>/dev/null || true
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
