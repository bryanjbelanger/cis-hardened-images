---
name: cis-ova-build
description: Build a CIS Server Level 1 hardened OVA for any supported Fedora-family EL target (Rocky/Alma/CentOS Stream 9 and 10) end to end in VMware Fusion — unattended kickstart install with OpenSCAP %post remediation, first-boot oscap audit, seal, and OVA export. Use when the user asks to build, rebuild, or audit a CIS/hardened OVA.
---

# CIS Server L1 hardened OVA (Fedora-family EL, VMware Fusion)

Targets are defined in `targets/*.env` (rocky9, rocky10, alma9, alma10, cs9,
cs10) — each carries hostname, ISO/checksum URLs, AppStream repo, SSG
datastream name, and EL major. All targets harden in %post via `oscap xccdf eval
--remediate`: the Anaconda OSCAP addon is unusable on EL10 (removed upstream)
AND on EL9 minimal media ("SCAP Security Guide not found on the system" — the
addon needs SSG content in the installer runtime, which only the DVD carries).
Optional FIPS: `FIPS=yes ./render.sh <target>` appends fips=1. CentOS Stream targets carry a documented
caveat: CIS benchmarks track RHEL releases and Stream runs ahead of them.
Below, TARGET is the target name and VM/hostname is `cis-<TARGET>`.

All VM and guest operations are MCP-only: `vmware-fusion` server for the
hypervisor, `virtualbox` server's `download_file` for verified fetches. Host
file prep (rendering the kickstart) uses local file tools.

## Preflight

- `mcp__vmware-fusion__vm` and `mcp__virtualbox__download_file` must be
  available. vmware-fusion needs env creds at registration:
  `VMRUN_GUEST_USER=root`, `VMRUN_GUEST_PASSWORD=<PW_ROOT_BUILD from
  local-creds.env>` — guest ops fail without them.
- Project dir: `~/Projects/cis-rocky-ova` (ks.cfg.tmpl, local-creds.env).
- Every download needs the user's explicit approval first.

## Phase 1 — Inputs

1. Install ISO (approval required, 1-2.5GB): fetch the target's CHECKSUM_URL,
   read the sha256 for the ISO named by ISO_URL, then
   `download_file url=<ISO_URL> sha256=<value>` (both from targets/TARGET.env).
2. Render kickstart: `./render.sh TARGET` → `build/TARGET/ks/ks.cfg`
   (gitignored), then validate:
   `.venv/bin/ksvalidator -v RHEL<EL_MAJOR> build/TARGET/ks/ks.cfg`.
3. `vm action=make_iso source_dir=build/TARGET/ks dest=build/TARGET/oemdrv.iso volume_label=OEMDRV`

## Phase 2 — Unattended install

4. `vm action=create vm=cis-TARGET disk_gb=25` (EFI, SATA, NAT — defaults fit)
5. `vm action=attach_iso vm=cis-TARGET iso_path=<target iso> device=sata0:1`
6. `vm action=attach_iso vm=cis-TARGET iso_path=build/oemdrv.iso device=sata0:2`
7. `vm action=start` — Anaconda finds OEMDRV, installs and remediates in
   %post, then powers off (kickstart
   `poweroff`). Poll `vm action=list` every few minutes; typical 20–40 min.
   Progress check while running: `vm action=capture_screen`.
8. Detach both ISOs: `attach_iso` with empty `iso_path` for sata0:1 and sata0:2.

## Phase 3 — First-boot audit (the standard tool: oscap)

9. `vm action=start`, wait for `vm action=ip` (proves vmtoolsd is up).
10. Audit: `guest action=run program=/usr/bin/oscap args=['xccdf','eval','--profile','xccdf_org.ssgproject.content_profile_cis_server_l1','--report','/root/cis-report.html','--results-arf','/root/cis-arf.xml','/usr/share/xml/scap/ssg/content/<SSG_DS from target env>']`
    — exit status 2 means rules failed (the tool call reports an error but the
    report files still exist; that is expected on a non-clean run).
11. `guest action=copy_from src=/root/cis-report.html dest=build/TARGET/cis-report.html`
    (and the ARF). Parse the report; enumerate every failed Server L1 rule.
12. Remediate: prefer fixing in ks.cfg.tmpl (%post) and rebuilding; for
    boot-time-irrelevant rules a `guest action=script` fix + re-audit is
    acceptable. Loop 10–12 until Server L1 shows no fails, or every remaining
    fail is documented as a knowing exception in the README.

## Phase 4 — Seal and export

13. `guest action=script` (root): shred /root/*-ks.cfg and /root/ks-post.log;
    initialize AIDE baseline (`aide --init` + move db into place);
    `chage -d 0 builder` (force password change); `passwd -l root` LAST —
    after this, guest ops as root stop working by design.
14. `vm action=stop` (soft), then `vm action=export_ova vm=cis-TARGET
    dest=build/TARGET/cis-TARGET-<date>.ova`.
15. Record the OVA's sha256 alongside it; report audit pass counts, any
    documented exceptions, and the artifact path. The OVA ships with root
    locked and builder expiring at first login (initial password in
    local-creds.env — rotate on distribution).
