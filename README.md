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

Eight targets in `targets/*.env`, two provisioner families:

| Provisioner | Targets | Installer | Delivery |
|---|---|---|---|
| `kickstart` | `rocky9` `rocky10` `alma9` `alma10` `cs9` `cs10` | Anaconda | ISO labeled **OEMDRV** |
| `autoinstall` | `ubuntu2404` `ubuntu2204` | Subiquity | ISO labeled **CIDATA** + repacked installer ISO |

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

**Both families ship a guest agent.** VMware images install `open-vm-tools`
(service `vmtoolsd`); VirtualBox images install `virtualbox-guest-additions` from
EPEL (service `vboxservice`). These are the distro-packaged Guest Additions —
GPLv2, with prebuilt kernel modules, so no compiler toolchain enters the image.
They are unrelated to Oracle's **Extension Pack**, which is proprietary (PUEL)
and is not used here.

Packer's `guest_additions_mode = "disable"` is therefore about the *build*, not
the image: it stops Packer attaching and uploading Oracle's Guest Additions ISO,
because the guest already gets the agent from EPEL.

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

| Rule | Status | Rationale |
|---|---|---|
| `grub2_password`, `grub2_uefi_password` | **Accepted exception** | A bootloader password baked into a distributable OVA is shared by every recipient, and does not protect an image whose virtual disk can simply be mounted. Deployers should run `grub2-setpassword` after deploying to a real host. |
| `service_systemd-journal-upload_enabled` | **Accepted exception** | Requires a remote log host in `/etc/systemd/journal-upload.conf`; there is no correct site-neutral value. Deployers configure their log server and enable the unit. |
| `ensure_redhat_gpgkey_installed` | **False positive** | The rule checks for Red Hat's GPG key; RHEL rebuilds ship their own vendor key. Not applicable to Rocky/Alma. |
| `service_nftables_enabled` (Ubuntu) | **Unsatisfiable pair** | The CIS Ubuntu profile contains BOTH `service_nftables_enabled` and `service_nftables_disabled`, because the benchmark expects one firewall utility to be chosen. ufw is Ubuntu's default, so nftables is masked and this rule cannot pass — exactly one of the pair fails whichever way you go. |
| `accounts_password_last_change_is_in_past` | **Build artifact** | Passwords are set minutes before the audit. The seal step's `chage -d 0 builder` resolves it in the shipped image. |
| `package_cron_installed` (AlmaLinux 9 and 10 only) | **False positive — upstream content bug** | The AlmaLinux datastreams check for a package named `cron`, which is the *Debian* name; EL ships `cronie`. The generated remediation is literally `rpm -q "cron" \|\| dnf install -y "cron"`, so the rule cannot pass on any RPM system. The image does have a working cron: the sibling rule *Enable cron Service* passes. Rocky's `ssg-rl10`/`ssg-rhel9` content checks `cronie` and passes. |
| `aide_build_database` (AlmaLinux 10 only) | **Measurement artifact** | The audit deliberately runs *before* the seal step, because sealing locks root and ends inspection — but the AIDE baseline is built *during* sealing. The shipped image does have one; the build's own seal log records `/var/lib/aide/aide.db.gz` at ~3.3 MB. Rocky 10 passes only because its content remediates the rule earlier, during the hardening pass. |
| `accounts_password_pam_unix_authtok` (AlmaLinux 10 only) | **Open — not yet diagnosed** | The remediation edits `/etc/pam.d/system-auth` directly, which EL10 manages through authselect, so the edit may not survive. Not verified: the VM is destroyed after sealing and the guest's PAM state was not captured. Listed here rather than left silently in the fail count. |

Fixed in `%post` rather than excepted: `sshd_limit_user_access`
(`AllowGroups wheel` — site policy, `builder` is in `wheel`),
`ensure_journald_and_rsyslog_not_active_together` (rsyslog masked),
`socket_systemd-journal-remote_disabled`, `service_bluetooth_disabled`.

## Notes for in-guest tooling

The minimal images ship **without `awk`**. Anything the pipeline runs inside a
guest must stick to `grep`/`sed`/shell builtins.
