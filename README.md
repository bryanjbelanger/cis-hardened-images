# CIS-hardened Linux images

Ready-to-run virtual machine images hardened to the **CIS Level 1 Server**
benchmark, built unattended and audited with OpenSCAP. Available for **VMware**
(Fusion, and Workstation on Windows or Linux) and **VirtualBox**.

Every image ships with the audit report that produced its published score, so
you can see exactly which rules pass, which fail, and why.

---

## Using an image

### 1. Verify what you downloaded

```bash
shasum -a 256 -c cis-<target>-<hypervisor>-amd64.ova.sha256
```

GitHub also publishes its own SHA-256 digest for every release asset, so
automated consumers can verify without the sidecar file.

### 2. Import

- **VMware Fusion / Workstation** — File → Import, select the `.ova`
- **VirtualBox** — File → Import Appliance, select the `.ova`

### 3. First login

| | |
|---|---|
| Username | `builder` |
| Password | `cis-hardened` |
| root | **locked** — use `sudo` |

**The password is expired on purpose.** You are forced to change it at first
login. This is a public image; that default is known to everyone until you
change it, so change it before putting the VM on a network you care about.

SSH is restricted to the `wheel` group (EL) or `sudo` group (Ubuntu) — add your
own accounts to that group, or edit `/etc/ssh/sshd_config.d/49-cis-access.conf`.

### 4. Do these before production use

The benchmark cannot be fully satisfied by an image alone. These are yours:

1. **Change the password** (forced at first login, but do not stop there — add
   an SSH key and consider disabling password auth).
2. **Set a bootloader password** — `grub2-setpassword` on EL. Shipped images
   deliberately have none; see the exceptions table below.
3. **Point logs somewhere** — configure `/etc/systemd/journal-upload.conf` if
   your policy requires remote logging.
4. **Re-run the audit yourself** after your changes:
   ```bash
   sudo oscap xccdf eval --profile <profile> --report ~/report.html \
     /usr/share/xml/scap/ssg/content/<datastream>
   ```
   The profile and datastream for each image are listed in its release notes.

---

## What is in the image

- **CIS Level 1 Server** hardening, applied with the OpenSCAP `scap-security-guide`
  content — the same open-source policy Red Hat ships and CIS-adjacent tooling
  uses. Nothing is hand-rolled.
- **CIS partition layout**: separate `/home`, `/tmp`, `/var`, `/var/tmp`,
  `/var/log`, `/var/log/audit` with `nodev,nosuid,noexec` as the benchmark
  requires.
- **auditd** enabled from first boot, **AIDE** file-integrity baseline built
  against the shipped state, **SELinux enforcing** (EL) / **AppArmor enforcing**
  (Ubuntu).
- Minimal package set plus the guest agent for its hypervisor.
- **No machine-id and no SSH host keys** — both regenerate on first boot, so
  cloned VMs do not share an identity.

### Optional FIPS builds

FIPS variants (EL only) boot with FIPS 140 mode enabled and a FIPS-based crypto
policy. Note that running in FIPS mode is **not** the same as being
FIPS-*certified*: certification attaches to specific validated module builds.
FIPS images also refuse MD5, SHA-1 signatures and older SSH ciphers, which
breaks older clients — take them only if you need them.

---

## Knowing what an image actually is

The release tag is a date, which says *when* an image was built and nothing
about *what* is in it. Three things vary independently — the OS point release,
the benchmark and SCAP content version, and package currency — and a date
cannot express any of them. So every release carries the answer in two places:

**`manifest.json`, attached to the release** — per asset: sha256, size, OS and
point release, benchmark name and version, SCAP profile, datastream, SSG content
version, FIPS mode, build date, and the audit pass/fail counts. Diff two
manifests and you can see precisely what changed between releases.

**`/etc/cis-image-release`, inside every image** — the same fields, so a running
VM answers "what am I, and what was I hardened against?" without reference to
where it came from. Modelled on `/etc/os-release`:

```bash
. /etc/cis-image-release && echo "$BENCHMARK ($SCAP_CONTENT_VERSION) — $AUDIT_PASS pass / $AUDIT_FAIL fail"
```

## Release and asset naming (contract for automated consumers)

Stable, predictable names — tooling resolves assets by exact name:

```
release tag:  v2026.08.04              <- the date lives HERE
assets:       cis-rocky9-vmware-amd64.ova
              cis-rocky9-vmware-amd64.ova.sha256
              cis-rocky9-virtualbox-amd64.ova
              cis-rocky9-virtualbox-amd64.ova.sha256
```

Three rules, and they exist for a reason:

1. **No date or version in the filename.** Consumers pick a release by tag
   (often `latest`) and then match the asset name exactly. A date-stamped
   filename cannot be predicted from `latest`.
2. **Hypervisor family in the name.** VMware and VirtualBox images genuinely
   differ (guest agent), so one release carries both and they must not collide.
3. **Architecture suffix.** Adding `arm64` builds later then changes nothing
   else about resolution.

## Upstream contributions

A bug found here was fixed and sent upstream —
[packer-plugin-virtualbox#192](https://github.com/hashicorp/packer-plugin-virtualbox/pull/192)
(EFI guests cannot boot ISOs on high SATA ports). See [UPSTREAM.md](UPSTREAM.md).

## Honest limitations

- **These images are not certified.** They are hardened against a published
  benchmark and audited with the standard scanner. That is evidence, not
  accreditation.
- **Two rules never pass**, by design — see the exceptions table below. Both are
  bootloader-password rules that only you can satisfy sensibly.
- **CIS Benchmark documents themselves are not redistributed here.** Rule
  identifiers and results are reported; the benchmark text belongs to CIS.

---

# Building the images

*Everything below is for maintaining the pipeline, not for using an image.*

## Supported targets

Nine targets in `targets/*.env`, three provisioner families:

| Provisioner | Targets | Installer | Delivery |
|---|---|---|---|
| `kickstart` | `rocky9` `rocky10` `alma9` `alma10` `cs9` `cs10` | Anaconda | ISO labeled **OEMDRV** |
| `autoinstall` | `ubuntu2404` `ubuntu2204` | Subiquity | ISO labeled **CIDATA** + repacked installer ISO |
| `preseed` | `debian12` | debian-installer | preseed embedded in a repacked ISO, named on the kernel cmdline |

The delivery column is the real difference between them. Anaconda and Subiquity
both discover their config from a volume LABEL; debian-installer discovers
nothing on its own, so Debian's preseed has to be named as a boot argument —
which is why `repack-iso.sh` exists.

### Benchmark variants

Each target can be built against either benchmark, with or without FIPS:

```bash
./build-packer.sh <target> <fusion|virtualbox> <no|yes> <cis|stig>
```

The variant is part of the artifact name — `cis-`, `cis-fips-`, `stig-`,
`stig-fips-` — because it has to be. Without it a FIPS build and its non-FIPS
sibling produce the identical file name, and a release upload publishes whichever
finished last under a name claiming to be the other.

| Variant | Profile | Notes |
|---|---|---|
| `cis` | CIS Level 1 Server | Default. What the published v2026.08.05 images are. |
| `cis-fips` | CIS L1 Server + FIPS | FIPS enabled with `fips-mode-setup`, crypto policy reconciled. |
| `stig` | DISA STIG | A much larger rule set: Rocky 9 scores 439/12 across 484 rules vs 274/2 across ~276 for CIS L1. |
| `stig-fips` | DISA STIG + FIPS | Clears `sysctl_crypto_fips_enabled`. Measured: Rocky 9 goes 12 fails → 11. |

**Debian has no STIG** — DISA publishes none and `ssg-debian12` carries only CIS
and ANSSI profiles. `build-packer.sh debian12 ... stig` refuses immediately
rather than failing inside oscap twenty minutes later.

Each target file carries its ISO/checksum URLs, repo URLs, SSG datastream, CIS
profile id, and provisioner. Render with `./render.sh <target|all>`, validate
with `./validate.sh <target|all>`.

Note the CIS profile id differs by family: EL uses `cis_server_l1`, Ubuntu uses
`cis_level1_server`. It is a per-target field, not a constant.

### Ubuntu: three facts that differ from EL

1. **`libopenscap8`, not `openscap-scanner`** — that package does not exist on
   jammy; `libopenscap8` ships `/usr/bin/oscap`. (Verify package existence with
   `apt-cache policy`, NOT by fetching packages.ubuntu.com — that page returns
   200 for nonexistent packages.)
2. **No packaged SCAP content on 22.04.** `ssg-debderived` is not in jammy at
   all. The pipeline stages a prebuilt datastream extracted from the *noble*
   `ssg-debderived` deb (~1.9MB), which carries both `ssg-ubuntu2204-ds.xml`
   and `ssg-ubuntu2404-ds.xml`. No SSG source build is needed.
3. **Post-boot fixes needed beyond oscap remediation** (found by auditing, all
   now part of the flow): `libpam-pwquality` must be installed or 12
   `accounts_password_pam_*` rules silently no-op; apparmor needs BOTH the
   `apparmor=1 security=apparmor` kernel args AND `aa-enforce /etc/apparmor.d/*`
   (117 profiles), then a reboot; `/snap/bin` is on root's PATH via
   `/etc/profile.d/apps-bin-path.sh` but does not exist on a minimal server, so
   create it or `root_path_all_dirs` fails (note: editing `/etc/environment` or
   `/etc/login.defs` does NOT fix this — the profile.d script re-adds it);
   `/etc/cron.allow` must exist root:root 0640; `/var/log` needs root:syslog.

4. **Hardening runs post-boot, not at install.** Subiquity installs `packages:`
   from the ISO only — its install-time sources are literally
   `deb [check-date=no] file:///cdrom jammy main restricted`, so any universe
   package there fails the install. `libpam-pwquality` in particular must be
   installed post-boot: without it, 12 `accounts_password_pam_*` rules silently
   fail to remediate.

Each build attempt needs a **fresh VM**: once a VM has an installed disk, EFI
NVRAM prefers booting it over the installer ISO, and a re-run will silently
boot the old system instead of installing.

### Ubuntu: the extra install step

Subiquity reads autoinstall config from a **CIDATA**-labeled volume, but that
alone does **not** make the install unattended: `autoinstall` must also be on
the kernel command line, or the installer stops and waits for a human to
confirm the destructive install. So Ubuntu targets need the stock installer ISO
repacked with that boot argument added — which requires `xorriso`
(`brew install xorriso`) on the build host. The EL targets need no equivalent
step, because Anaconda auto-loads OEMDRV without any boot argument.

### Debian proper

Deliberately not a target yet. SSG publishes a CIS **Workstation** profile for
Debian 12 but no `cis_level1_server`, so there is no server baseline to build
against. Ubuntu LTS is the Debian-family server target until that changes.

Plain Fedora is deliberately excluded: it has no CIS SSG profile. CentOS Stream
targets carry a caveat — CIS benchmarks track RHEL releases, and Stream runs
ahead of them, so its `cis_server_l1` content can drift from the published
benchmark.

### One hardening mechanism: `%post` remediation

Every target runs `oscap xccdf eval --remediate` in `%post`. The Anaconda
OSCAP addon is not usable on either end of the matrix:

- **EL10** removed `oscap-anaconda-addon` upstream, and the
  `%addon com_redhat_oscap` kickstart syntax with it.
- **EL9 minimal ISOs** abort the install with *"SCAP Security Guide not found
  on the system"* — the addon needs SSG content inside the installer runtime,
  which only the full DVD image carries.

`%post` remediation needs nothing but the packages the kickstart already
installs, and is verified equivalent: rules that must hold before first boot
(the CIS partition layout and its mount options) are *declared* in the
kickstart rather than retrofitted, and all 21 of those rules pass on the built
image.

### FIPS mode (optional, off by default) — verified on Rocky 9

`FIPS=yes` enables FIPS 140 mode via `fips-mode-setup --enable` in `%post`.

**It does NOT set `fips=1` on the bootloader line, and must not.** With a
separate `/boot` — which the CIS partition layout mandates — dracut's FIPS
module also needs `boot=UUID=<uuid>` to verify the kernel HMAC, and that UUID
does not exist when the kickstart is authored. Setting `fips=1` alone produces
a system that installs fine and then never boots (verified: no console login,
no network, no VMware Tools). `fips-mode-setup` writes both arguments, pulls in
the dracut FIPS support, and rebuilds the initramfs.

**A second conflict, also handled:** CIS remediation installs a DEFAULT-based
custom crypto policy that overwrites the FIPS policy, leaving
`fips-mode-setup --check` reporting *"Inconsistent state detected"*. The
template therefore re-applies the same CIS sub-policies on a FIPS base after
remediation (`FIPS:NO-SHA1:NO-SSHCBC:...`), so both hold.

Measured cost of FIPS: **none**. Rocky 9 with FIPS audits 274 pass / 2 fail /
17 N/A — identical to the non-FIPS build, with all 21 partition/mount rules
passing and MD5 correctly refused by OpenSSL.

Set it per target in `targets/<name>.env` for a standing choice, or per render:

```
FIPS=yes ./render.sh rocky9
```

FIPS is orthogonal to CIS: `cis_server_l1` does **not** require it — the DISA
STIG profiles (`stig`, `stig_gui`, also in these datastreams) are what do. Turn
it on for US federal / DoD / FedRAMP-adjacent destinations. Note that running
in FIPS mode is not the same as being FIPS-*certified*: certification attaches
to specific validated module builds, so an EL rebuild gets the posture, not the
certificates.

Every rendered kickstart is syntax-checked with `ksvalidator` against its EL
version (`.venv/bin/ksvalidator -v RHEL9|RHEL10 build/<target>/ks/ks.cfg`).

## How it works

1. **ks.cfg.tmpl** — one parameterized kickstart applying
   `xccdf_org.ssgproject.content_profile_cis_server_l1` (mechanism per EL major,
   above). CIS partition layout, auditd from the first boot, minimal package
   set, open-vm-tools as the MCP control channel. Minimal-ISO targets also pull
   the network BaseOS repo: the media's BaseOS is a subset, and on EL10
   open-vm-tools needs `fuse3`/`dbus-tools` that it lacks.
2. **OEMDRV delivery** — the rendered ks.cfg is burned into a tiny ISO labeled
   `OEMDRV`; Anaconda auto-loads it. No boot-menu editing, fully unattended.
3. **Audit** — after first boot, `oscap xccdf eval` (the standard SCAP tool)
   runs against the same profile; the HTML report and ARF results are pulled to
   the host. The loop continues until Server L1 is clean or exceptions are
   documented here.
4. **Seal** — kickstart copies (which contain build passwords) are shredded,
   the AIDE baseline is initialized against the final state, `builder`'s
   password is expired, root is locked, and the VM is exported to `.ova`.

The full operational procedure is the bundled skill:
[skills/cis-ova-build](skills/cis-ova-build/SKILL.md).

## Credentials model

`local-creds.env` (gitignored, generated) holds the two build passwords. The
rendered `build/ks/ks.cfg` is also gitignored. The shipped OVA has **root
locked** and **builder expiring at first login**. The vmware-fusion MCP server
receives guest credentials only via environment at registration — never
through tools.

## Verified results

Both EL majors built, booted, and audited with `oscap xccdf eval` against
`cis_server_l1` (2026-08-02):

| Target | Datastream | Profile | Pass | Fail | N/A | Total |
|---|---|---|---:|---:|---:|---:|
| Rocky 9 | `ssg-rl9-ds.xml` | `cis_server_l1` | 274 | **2** | 17 | 293 |
| Rocky 10 | `ssg-rl10-ds.xml` | `cis_server_l1` | 300 | 8 | 15 | 323 |
| Ubuntu 22.04 | `ssg-ubuntu2204-ds.xml` (staged) | `cis_level1_server` | 353 | **3** | 37 | 398 |
| Ubuntu 24.04 (sealed, shipped) | `ssg-ubuntu2404-ds.xml` (staged) | `cis_level1_server` | 360 | **2** | 39 | 408 |
| Rocky 9 + FIPS | `ssg-rl9-ds.xml` | `cis_server_l1` | 274 | **2** | 17 | 293 |
| Rocky 9 on **VirtualBox** | `ssg-rl9-ds.xml` | `cis_server_l1` | 274 | **2** | 17 | 293 |
| Ubuntu 24.04 | `ssg-ubuntu2404-ds.xml` (staged) | `cis_level1_server` | 360 | **2** | 39 | 408 |

All 21 partition and mount-option rules pass on all four — `/tmp` and `/dev/shm`
separation, plus `nodev`/`nosuid`/`noexec` across `/home`, `/tmp`, `/var`,
`/var/tmp`, `/var/log`, `/var/log/audit`, `/dev/shm`.

Rocky 9's two failures are exactly the two accepted exceptions below
(`grub2_password`, `accounts_password_last_change_is_in_past` — the latter
self-resolves at seal), i.e. **zero unexplained failures**. Rocky 10 was built
before the `%post` policy fixes landed; rebuilding it should drop its count to
the same set. Its extra failures were `sshd_limit_user_access`, the two
journald/rsyslog rules, `service_bluetooth_disabled` (all now fixed in `%post`),
plus `ensure_redhat_gpgkey_installed` and
`service_systemd-journal-upload_enabled` (both excepted below).

## Hypervisor portability

> Hit a VirtualBox build that hangs at `Waiting for SSH` with a 2 MB disk? It is
> almost certainly VRAM, not what you think. See
> [TROUBLESHOOTING.md](TROUBLESHOOTING.md) before investigating — it also lists
> three plausible causes that have already been tested and ruled out.

The same kickstart builds identically on **VMware Fusion** and **VirtualBox**:
Rocky 9 scores 274 pass / 2 fail on both, with all 21 partition/mount rules
passing. The OEMDRV delivery mechanism, the CIS layout and the `%post`
remediation are all hypervisor-independent — only VM creation and guest access
differ, and those live in the MCP servers, not the provisioning files.

Fusion and VMware Workstation share the VMX/VMDK format, so a Fusion build
covers both; keep `virtualHW.version` conservative (19) so older Workstation
releases can open the result.

**Guest agents differ by hypervisor, and one combination has none.**

| Image | Guest agent | `guestcontrol` / `vmrun` guest ops |
|---|---|---|
| VMware (all targets) | `open-vm-tools` (`vmtoolsd`) | works |
| VirtualBox + Ubuntu | `virtualbox-guest-utils` (universe) | works |
| **VirtualBox + EL** (Rocky, Alma, CentOS Stream) | **none** | **not available — use SSH** |

Enterprise Linux VirtualBox images ship without Guest Additions because there is
currently no way to get them:

* EL has no packaged Guest Additions. EPEL 9 ships nothing named `virtualbox` at
  all — a kickstart requesting one leaves Anaconda stuck at an interactive
  "missing packages … ignore?" prompt.
* Oracle's Guest Additions ISO does not compile against RHEL 9.8's kernel:
  `fileio-r0drv-linux.c: implicit declaration of 'open_with_fake_path'`. RHEL
  reports kernel 5.14 but carries heavy backports, so VirtualBox's
  version-gated compatibility code takes the wrong branch. Forcing it past
  `-Werror` does not help — the symbol genuinely is not present.
* Rocky 9 ships no in-tree module either; `drivers/virt/` contains only `coco`
  and `nitro_enclaves`.

Practical effect: drive EL VirtualBox guests over **SSH** rather than
`VBoxManage guestcontrol`. The build itself works this way, so the path is well
tested. This will be revisited when Oracle ships Guest Additions sources that
understand RHEL 9's backported kernels.

Guest Additions are GPLv2 open source. Oracle's **Extension Pack** is the
proprietary (PUEL) component, and nothing here uses it.

**Guest access during the build is SSH over a NAT port-forward on VirtualBox.**
That is simply Packer's communicator, driving the installed system the same way
on both hypervisors — not a consequence of any missing agent. Note the hardened
sshd rate-limits connections (`MaxStartups`): drive it with one connection at a
time, not a burst.

## Distribution

A sealed Ubuntu 24.04 image exports to **1.51 GB** — under GitHub's 2 GiB
release-asset cap, with ~0.5 GB headroom. Free-space zeroing is what makes this
work: the same image exported at **2.85 GB** before zeroing, and `--compress=9`
alone only reached 2.81 GB, because unallocated blocks held deleted-file
garbage that will not compress.

Shrinking the virtual disk does NOT help meaningfully: OVA size tracks
*allocated* blocks, not the declared size. The measured image had ~2.9 GB of
live data inside a 5.2 GB allocated disk on a 25 GB declaration.

## Known-exceptions log

Every rule that fails in a published image is listed here — there are no
undocumented failures. Each row says what it is, why it is not fixed in the
image, and **what you should do about it on a deployed host**.

Check your own image at any time:

```bash
sudo oscap xccdf eval --profile "$(grep ^SCAP_PROFILE= /etc/cis-image-release | cut -d\" -f2)" \
  --report /root/cis-report.html \
  "/usr/share/xml/scap/ssg/content/$(grep ^SCAP_DATASTREAM= /etc/cis-image-release | cut -d\" -f2)"
```

| Rule | Status | Why it fails | What you should do |
|---|---|---|---|
| `grub2_password`, `grub2_uefi_password` | **Accepted exception** | A bootloader password baked into a distributable OVA is shared by every recipient, and protects nothing on an image whose virtual disk can simply be mounted. | **Set one after deploying.** EL: `sudo grub2-setpassword`. Ubuntu: generate a hash with `grub-mkpasswd-pbkdf2`, add `set superusers` / `password_pbkdf2` to `/etc/grub.d/40_custom`, then `sudo update-grub`. |
| `service_systemd-journal-upload_enabled` | **Accepted exception** | Needs a remote log host; there is no correct site-neutral value to ship. | **Point it at your log server.** Set `URL=` in `/etc/systemd/journal-upload.conf`, then `sudo systemctl enable --now systemd-journal-upload`. |
| `accounts_password_last_change_is_in_past` | **Build artifact** | Passwords are set minutes before the audit runs. | **Nothing.** Resolved the moment you change the `builder` password at first login, which is forced. Confirm with `sudo chage -l builder`. |
| `ensure_redhat_gpgkey_installed` (Rocky) | **False positive** | Checks for Red Hat's GPG key specifically; RHEL rebuilds ship their own vendor key. | **Nothing.** Confirm your vendor key is present: `rpm -q gpg-pubkey --qf '%{SUMMARY}\n'`. |
| `package_cron_installed` (AlmaLinux) | **False positive — upstream content bug** | Alma's datastreams check for a package named `cron`, the Debian name. EL ships `cronie`, so the check cannot pass on any RPM system. The sibling rule *Enable cron Service* passes. | **Nothing.** Confirm cron really is there: `rpm -q cronie && systemctl is-enabled crond`. |
| `aide_build_database` (AlmaLinux 10) | **Measurement artifact** | The audit runs before the seal step, and the AIDE baseline is built *during* sealing. | **Nothing to fix, but re-baseline after you configure the host:** `sudo aide --init && sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz`. Verify the shipped one with `ls -l /var/lib/aide/aide.db.gz`. |
| `service_nftables_enabled` (Ubuntu) | **Unsatisfiable pair** | The CIS Ubuntu profile contains BOTH `service_nftables_enabled` and `service_nftables_disabled` — the benchmark expects you to pick one firewall. ufw is Ubuntu's default, so nftables is masked and exactly one of the pair fails whichever way you go. | **Decide, do not chase the rule.** Keep ufw (`sudo ufw status`), or switch: `sudo systemctl unmask --now nftables && sudo ufw disable`. |
| `accounts_password_pam_unix_authtok` (AlmaLinux 10) | **Open — not yet diagnosed** | The rule wants `use_authtok` on the `pam_unix.so` password line. Its remediation edits `/etc/pam.d/system-auth` directly, which EL10 manages through authselect, so the edit may not survive. Root cause not confirmed. | **Check, and fix via authselect if your policy requires it.** Inspect with `grep pam_unix /etc/pam.d/system-auth`. If `use_authtok` is absent, add it in an authselect custom profile rather than editing the file directly (`authselect create-profile`, edit, `authselect select custom/<name>`, `authselect apply-changes`) — a direct edit will be reverted. |

### STIG profile exceptions

STIG images (`stig-*` assets) are audited against the DISA STIG profile, a much
larger rule set than CIS Level 1 — Rocky 9 scores **439 pass / 12 fail across
484 rules**, versus 274/2 across ~276 for CIS L1. A higher fail *count* here
does not mean a weaker image; it is a bigger benchmark.

| Rule | Status | Why it fails | What you should do |
|---|---|---|---|
| `sysctl_crypto_fips_enabled` (EL10 also `enable_fips_mode`, `system_booted_in_fips_mode`) | **Fixed by the FIPS variant** | STIG expects FIPS mode; the plain `stig` image does not enable it. | **Use the `stig-fips-*` asset** (verified: Rocky 9 goes 12 fails → 11, `FIPS_MODE=1`). On a deployed non-FIPS host: `sudo fips-mode-setup --enable && sudo reboot`. |
| `harden_sshd_macs_openssh_conf_crypto_policy`, `harden_sshd_macs_opensshserver_conf_crypto_policy` | **Open — NOT fixed by FIPS** | Initially grouped with the FIPS rules above; the `stig-fips` build disproved that — both still fail with `FIPS_MODE=1`. The STIG wants explicit MAC lists in the openssh crypto-policy drop-ins, which the CIS-style policy this image applies does not write. | Inspect `/etc/crypto-policies/back-ends/openssh.config` and `opensshserver.config`. If your policy requires the STIG MAC list, set it explicitly rather than relying on the crypto policy. |
| `network_configure_name_resolution` | **Site-specific** | Requires real resolvers; there is no correct value to ship. | Set your DNS servers in `/etc/resolv.conf` (or via NetworkManager) and re-audit. |
| `chronyd_server_directive` | **Site-specific** | Requires your NTP source. | Add `server <your-ntp-host> iburst` to `/etc/chrony.conf`, then `sudo systemctl restart chronyd`. |
| `sssd_enable_certmap` | **Site-specific** | Smart-card certificate mapping needs an identity domain. | Configure `sssd` certmap for your domain, or accept if you do not use smart cards. |
| `grub2_password`, `grub2_admin_username` | **Accepted exception** | Same reasoning as CIS — a bootloader password shared by every recipient protects nothing. | `sudo grub2-setpassword` after deploying. |
| `installed_OS_is_vendor_supported` | **False positive** | The RHEL STIG checks for Red Hat vendor support; this is a rebuild. | Nothing. Same class as `ensure_redhat_gpgkey_installed`. |
| `accounts_authorized_local_users` | **Build artifact** | The `builder` account is not in STIG's expected user list. | Remove or rename `builder` once you have your own admin account. |
| `sysctl_user_max_user_namespaces_no_remediation` | **Manual by design** | The rule name says it: SSG ships no automated remediation, because disabling user namespaces breaks containers. | Decide per host. Set `user.max_user_namespaces=0` only if nothing on the box needs them. |
| `selinux_context_elevation_for_sudo` | **Open — not yet diagnosed** | Not investigated. Recorded rather than omitted. | Inspect `sudo -V | grep -i selinux` and your sudoers `TYPE`/`ROLE` settings if your policy requires it. |

**No STIG for Debian.** DISA publishes none, and `ssg-debian12` carries only CIS
and ANSSI profiles. `build-packer.sh debian12 ... stig` refuses with that
reason rather than failing inside oscap twenty minutes later.

Fixed in `%post` rather than excepted: `sshd_limit_user_access`
(`AllowGroups wheel` — site policy, `builder` is in `wheel`),
`ensure_journald_and_rsyslog_not_active_together` (rsyslog masked),
`socket_systemd-journal-remote_disabled`, `service_bluetooth_disabled`.

## Notes for in-guest tooling

The minimal images ship **without `awk`**. Anything the pipeline runs inside a
guest must stick to `grep`/`sed`/shell builtins.
