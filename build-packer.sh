#!/usr/bin/env bash
# Wrapper around `packer build` that makes runs repeatable.
#
# Packer leaves a VM behind on failure (we pass -on-error=abort deliberately —
# post-mortems on broken builds have found nearly every root cause in this
# project). But a leftover VM then breaks the NEXT run: deleting its directory
# while vmware-vmx still holds it leaves a zombie process, and the VMware
# plugin's VNC step fails with "connection refused".
#
# So: always stop leftovers BEFORE clearing the output directory.
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${1:?usage: build-packer.sh <target> [fusion|virtualbox] [fips]}"
HV="${2:-fusion}"
FIPS_MODE="${3:-no}"
VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"

case "$HV" in
  fusion)     ONLY="cis.vmware-iso.cis";     HYPERVISOR=vmware;     OUT_SUFFIX=vmware ;;
  virtualbox) ONLY="cis.virtualbox-iso.cis"; HYPERVISOR=virtualbox; OUT_SUFFIX=virtualbox ;;
  *) echo "hypervisor must be fusion|virtualbox" >&2; exit 1 ;;
esac

# The output directory is named after vm_name, NOT the target — read it from the
# vars file rather than guessing, or the pre-clean misses and packer aborts with
# "output directory already exists".
VM_NAME=$(grep -E '^\s*vm_name' "packer/vars/${TARGET}.pkrvars.hcl" | cut -d'"' -f2)
OUT_DIR="build/packer/${VM_NAME}-${OUT_SUFFIX}"

echo "==> stopping any leftover build VMs"
# `grep` exits 1 when nothing matches, which is the NORMAL case here — with
# `set -euo pipefail` that silently killed the whole script. Hence `|| true`.
# Scope to THIS build's VM only. Matching all of build/packer killed a
# concurrently-running build of the other hypervisor — the cleanup must never
# touch a sibling build.
"$VMRUN" -T fusion list 2>/dev/null | grep -F "$(pwd)/$OUT_DIR/" || true | while read -r vmx; do
  [ -n "${vmx:-}" ] || continue
  echo "    stopping $(basename "$vmx")"; "$VMRUN" -T fusion stop "$vmx" hard >/dev/null 2>&1 || true
done
# VirtualBox registers machines by name GLOBALLY, so a leftover registration —
# even powered off — makes the next build fail with "Machine settings file
# already exists". Stopping is not enough; it must be unregistered and deleted.
if [ "$HV" = virtualbox ]; then
  if VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; then
    echo "    removing existing vbox VM $VM_NAME"
    VBoxManage controlvm "$VM_NAME" poweroff >/dev/null 2>&1 || true
    sleep 2
    VBoxManage unregistervm "$VM_NAME" --delete >/dev/null 2>&1 || true
  fi
  rm -rf "$HOME/VirtualBox VMs/$VM_NAME"
fi
# WAIT for vmware-vmx to actually exit before touching the directory. A fixed
# `sleep 3` was not enough: removing the VM's files while the process still held
# them left a zombie vmx, and the next build died with
# "error connecting to VNC: connection refused".
for _ in $(seq 1 30); do
  pgrep -f "vmware-vmx.*$(basename "$OUT_DIR")" >/dev/null 2>&1 || break
  sleep 2
done
if pgrep -f "vmware-vmx.*$(basename "$OUT_DIR")" >/dev/null 2>&1; then
  echo "    vmx still alive after 60s — force killing"
  pkill -f "vmware-vmx.*$(basename "$OUT_DIR")" || true
  sleep 5
fi
echo "    clearing $OUT_DIR"
rm -rf "$OUT_DIR"

echo "==> rendering (DRIVER=packer, HYPERVISOR=$HYPERVISOR, FIPS=$FIPS_MODE)"
export RENDER_SUFFIX="-${HV}"
DRIVER=packer HYPERVISOR="$HYPERVISOR" FIPS="$FIPS_MODE" ./render.sh "$TARGET"
./validate.sh "$TARGET"

echo "==> packer build"
# Ubuntu (autoinstall) differs from EL only in the delivery volume, the config
# directory, and needing a datastream staged in — see prepare.sh.
source "targets/${TARGET}.env"
EXTRA=()   # NOTE: expanded below as ${EXTRA[@]+"${EXTRA[@]}"} — macOS ships
           # bash 3.2, where "${EXTRA[@]}" on an EMPTY array trips `set -u`.
if [ "${PROVISIONER:-kickstart}" = autoinstall ]; then
  EXTRA+=(-var "cd_label=CIDATA" -var "provisioning_dir=cidata")
  DS="build/ssgx/usr/share/xml/scap/ssg/content/${SSG_DS}"
  [ -f "$DS" ] && EXTRA+=(-var "staged_datastream=$(pwd)/$DS")
fi

exec packer build -on-error=abort -only="$ONLY" \
  -var "render_suffix=-${HV}" ${EXTRA[@]+"${EXTRA[@]}"} \
  -var-file="packer/vars/${TARGET}.pkrvars.hcl" packer/
