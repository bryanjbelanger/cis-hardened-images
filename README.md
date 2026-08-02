# cis-rocky-ova

Builds **CIS Server Level 1 hardened OVAs** for the Fedora-family EL
distributions from clean ISOs, fully unattended, driven end-to-end through MCP
servers (VMware Fusion for the hypervisor, checksum-verified downloads via the
virtualbox server's tooling).

## Supported targets

One kickstart template, six targets in `targets/*.env` — `rocky9`, `rocky10`,
`alma9`, `alma10`, `cs9`, `cs10`. Each carries its ISO/checksum URLs, repo
URLs, SSG datastream name, and EL major. Render with `./render.sh <target>`
(or `all`).

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

### FIPS mode (optional, off by default)

`FIPS=yes` appends `fips=1` to the kernel command line so the system comes up
in FIPS mode with keys and initramfs generated under it — cleaner than
retrofitting with `fips-mode-setup`, which leaves pre-FIPS key material behind.
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

| Target | Datastream | Pass | Fail | N/A | Total |
|---|---|---:|---:|---:|---:|
| Rocky 9 | `ssg-rl9-ds.xml` | 274 | **2** | 17 | 293 |
| Rocky 10 | `ssg-rl10-ds.xml` | 300 | 8 | 15 | 323 |

All 21 partition and mount-option rules pass on both — `/tmp` and `/dev/shm`
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

## Known-exceptions log

| Rule | Status | Rationale |
|---|---|---|
| `grub2_password` | **Accepted exception** | A bootloader password baked into a distributable OVA is shared by every recipient, and does not protect an image whose virtual disk can simply be mounted. Deployers should run `grub2-setpassword` after deploying to a real host. |
| `service_systemd-journal-upload_enabled` | **Accepted exception** | Requires a remote log host in `/etc/systemd/journal-upload.conf`; there is no correct site-neutral value. Deployers configure their log server and enable the unit. |
| `ensure_redhat_gpgkey_installed` | **False positive** | The rule checks for Red Hat's GPG key; RHEL rebuilds ship their own vendor key. Not applicable to Rocky/Alma. |
| `accounts_password_last_change_is_in_past` | **Build artifact** | Passwords are set minutes before the audit. The seal step's `chage -d 0 builder` resolves it in the shipped image. |

Fixed in `%post` rather than excepted: `sshd_limit_user_access`
(`AllowGroups wheel` — site policy, `builder` is in `wheel`),
`ensure_journald_and_rsyslog_not_active_together` (rsyslog masked),
`socket_systemd-journal-remote_disabled`, `service_bluetooth_disabled`.

## Notes for in-guest tooling

The minimal images ship **without `awk`**. Anything the pipeline runs inside a
guest must stick to `grep`/`sed`/shell builtins.
