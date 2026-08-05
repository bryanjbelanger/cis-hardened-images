#!/usr/bin/env bash
# Generate packer/vars/<target>.pkrvars.hcl from targets/<target>.env plus the
# locally cached ISO, so the two never drift.
set -euo pipefail
cd "$(dirname "$0")"
T="${1:?usage: gen-vars.sh <target>}"
source "targets/${T}.env"
source local-creds.env

ISO=$(ls build/*.iso 2>/dev/null | grep -iE "$(echo "$TARGET" | sed 's/rocky\([0-9]*\)/Rocky-\1/i;s/alma\([0-9]*\)/AlmaLinux-\1/i;s/ubuntu\([0-9][0-9]\)\([0-9][0-9]\)/ubuntu-\1.\2/i')" | head -1)
[ -n "$ISO" ] || { echo "no cached ISO for $T in build/ — download it first" >&2; exit 1; }

mkdir -p packer/vars
cat > "packer/vars/${T}.pkrvars.hcl" <<VARS
target       = "${TARGET}"
vm_name      = "cis-${TARGET}"
iso_url      = "file://$(pwd)/${ISO}"
iso_checksum = "sha256:$(shasum -a 256 "$ISO" | cut -d' ' -f1)"
ssg_ds       = "${SSG_DS}"
cis_profile  = "${CIS_PROFILE}"
guest_os_type_vmware     = "${VMWARE_GUEST_OS:-centos9-64}"
guest_os_type_virtualbox = "${VBOX_GUEST_OS:-RedHat9_64}"
ssh_password  = "${PW_BUILDER}"
root_password = "${PW_ROOT_BUILD}"
VARS
chmod 600 "packer/vars/${T}.pkrvars.hcl"
echo "wrote packer/vars/${T}.pkrvars.hcl (iso: $(basename "$ISO"))"
