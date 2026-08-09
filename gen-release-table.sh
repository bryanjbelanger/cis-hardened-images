#!/usr/bin/env bash
# Print the release-notes image table from manifest.json.
#
# WHY: the table was hand-maintained and drifted — it claimed "VMware only;
# VirtualBox images follow" for a day after the VirtualBox images shipped, listed
# 5 of 20 images, and gave a verify command that only worked for CIS/VMware
# assets. Generating it from the manifest means the published numbers cannot
# disagree with the published images.
#
#   ./gen-release-table.sh manifest.json
set -euo pipefail
M="${1:?usage: gen-release-table.sh <manifest.json>}"

python3 - "$M" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
imgs = m["images"]

# target -> variant -> hypervisor -> "pass/fail"
by = {}
osname = {}
for i in imgs:
    a = i.get("audit") or {}
    score = f"{a.get('pass','?')}/{a.get('fail','?')}"
    by.setdefault(i["target"], {}).setdefault(i["variant"], {})[i["hypervisor"]] = score
    if i.get("os") and i["os"] != "unknown":
        osname[i["target"]] = i["os"]

def cell(varmap, variant):
    hv = varmap.get(variant)
    if not hv:
        return "—"
    vm, vb = hv.get("vmware"), hv.get("virtualbox")
    if vm and vb:
        return vm if vm == vb else f"{vm} · vbox {vb}"
    return vm or vb or "—"

order = ["rocky9", "rocky10", "alma9", "alma10", "ubuntu2404", "debian12"]
targets = [t for t in order if t in by] + [t for t in sorted(by) if t not in order]

print("| Target | OS | CIS L1 Server | DISA STIG | STIG + FIPS |")
print("|---|---|---|---|---|")
for t in targets:
    v = by[t]
    print(f"| {t} | {osname.get(t,'—')} | {cell(v,'cis')} | {cell(v,'stig')} | {cell(v,'stig-fips')} |")

print()
print(f"{len(imgs)} images. Where a target's two hypervisors differ, the VirtualBox")
print("score is shown after `vbox`; the difference is normally")
print("`network_configure_name_resolution`, which depends on whether the")
print("hypervisor's NAT hands the guest a resolver.")
PYEOF
