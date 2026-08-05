#!/usr/bin/env bash
# Build and install VirtualBox Guest Additions from Oracle's ISO, inside the
# guest, as root. VirtualBox targets only.
#
# WHY THIS EXISTS
# EL has no packaged Guest Additions — EPEL 9 ships nothing named virtualbox at
# all. The kickstart used to request "virtualbox-guest-additions" from EPEL,
# which left Anaconda sitting at an interactive "missing packages ... ignore?"
# prompt forever. Oracle's ISO is the only real source on this family, and it
# ships source that must be compiled against the running kernel.
#
# Guest Additions are what `VBoxManage guestcontrol` talks to, so this is what
# lets the VirtualBox MCP server drive the shipped image the same way VMware's
# open-vm-tools lets vmrun drive its images.
#
# THE TOOLCHAIN IS REMOVED AGAIN at the end. A hardened image has no business
# shipping a compiler. The consequence, accepted deliberately: a guest kernel
# update will leave the modules unbuilt, and Guest Additions must be
# reinstalled after one. That is recorded in /etc/cis-image-release notes and
# the README.
set -uo pipefail
set +e   # several steps return non-zero harmlessly; Packer runs us with -e

log() { echo "[guest-additions] $*"; }

ISO=/tmp/VBoxGuestAdditions.iso
MNT=/mnt/vboxga

if [ ! -f "$ISO" ]; then
  log "ERROR: $ISO not present — Packer's guest_additions_mode should have uploaded it"
  exit 1
fi
log "iso: $(stat -c %s "$ISO" 2>/dev/null || echo '?') bytes"

# The build needs headers for the RUNNING kernel. The kickstart installs
# kernel-devel, but if the installer media and the network repo disagree on
# kernel version the headers can mismatch — check rather than fail obscurely
# three steps later.
KVER=$(uname -r)
if [ ! -d "/usr/src/kernels/$KVER" ]; then
  log "kernel-devel for $KVER missing, installing"
  dnf install -y "kernel-devel-$KVER" >/dev/null 2>&1 || dnf install -y kernel-devel >/dev/null 2>&1
fi
[ -d "/usr/src/kernels/$KVER" ] \
  && log "headers present for $KVER" \
  || log "WARNING: no headers for $KVER — module build will likely fail"

install -d "$MNT"
mount -o loop,ro "$ISO" "$MNT" || { log "ERROR: could not mount $ISO"; exit 1; }

# --nox11 keeps it from pulling X pieces onto a server image. Exit code 2 means
# "installed, but X/desktop bits skipped", which is exactly what we want here.
log "building modules (this takes a couple of minutes)"
"$MNT/VBoxLinuxAdditions.run" --nox11 --accept > /tmp/vboxga-install.log 2>&1
rc=$?
log "VBoxLinuxAdditions.run exit=$rc"
[ $rc -ne 0 ] && [ $rc -ne 2 ] && tail -20 /tmp/vboxga-install.log

umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null

# Oracle's own log is the authoritative one and says WHY a module build failed;
# the installer's stdout only says that it did. Stage it where the build can
# download it — the VM is destroyed after sealing, so anything not copied out
# here is unrecoverable.
if [ -f /var/log/vboxadd-setup.log ]; then
  cp /var/log/vboxadd-setup.log /tmp/vboxadd-setup.log 2>/dev/null
  chmod a+r /tmp/vboxadd-setup.log 2>/dev/null
fi

# Verify against reality, not against the installer's exit code — this project
# has been bitten before by a step that reported success and did nothing.
modprobe vboxguest 2>/dev/null
if lsmod | grep -q vboxguest; then
  log "vboxguest module loaded"
else
  log "ERROR: vboxguest not loaded — Guest Additions are NOT functional"
  log "  compiler errors from /var/log/vboxadd-setup.log:"
  grep -iE 'error:|fatal|No such file' /var/log/vboxadd-setup.log 2>/dev/null | head -15 | sed 's/^/  | /'
  log "  installer tail:"
  tail -15 /tmp/vboxga-install.log 2>/dev/null | sed 's/^/  | /'
  # Deliberately DO NOT remove the toolchain: leaving it lets the failure be
  # retried or debugged, and an image that silently lacks its guest agent is
  # exactly the kind of quiet breakage this pipeline exists to avoid.
  log "leaving build toolchain installed so this can be retried"
  exit 1
fi

for unit in vboxadd vboxadd-service; do
  systemctl enable "$unit" >/dev/null 2>&1 && log "enabled $unit"
done

if ! command -v VBoxService >/dev/null 2>&1; then
  log "ERROR: VBoxService missing despite modules loading — guestcontrol will not work"
  exit 1
fi
log "VBoxService present: $(VBoxService --version 2>/dev/null | head -1)"

# Remove the build toolchain. Ordering matters: only reached once the modules
# genuinely exist and loaded.
log "removing build toolchain from the image"
dnf remove -y gcc make kernel-devel elfutils-libelf-devel >/dev/null 2>&1
dnf clean all >/dev/null 2>&1
command -v gcc >/dev/null 2>&1 \
  && log "WARNING: gcc still present after removal" \
  || log "gcc removed"

rm -f "$ISO"
log "guest additions complete and verified"
exit 0
