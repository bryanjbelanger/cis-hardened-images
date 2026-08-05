CIS Level 1 Server hardened images, built unattended and audited with OpenSCAP.

**Marked pre-release**: the images themselves are complete and audited, but this
is the first release cut from this pipeline and the automated publish path has
not yet been exercised end to end. Treat the artifacts as real; treat the
release process as new.

## Assets

| Asset | Hypervisor |
|---|---|
| `cis-rocky9-vmware-amd64.ova` | VMware Fusion / Workstation (Windows or Linux) |
| `cis-rocky9-virtualbox-amd64.ova` | VirtualBox |

Each ships with a `.sha256` sidecar; GitHub also publishes its own digest for
every asset, so automated consumers can verify without it.

Audit and seal logs are attached as build evidence — the same numbers quoted
below, straight from the build that produced these images.

## Audit result

**274 pass / 2 fail / 17 not-applicable** of 293 rules, profile
`xccdf_org.ssgproject.content_profile_cis_server_l1` against `ssg-rl9-ds.xml`.

All 21 partition and mount-option rules pass: `/tmp` and `/dev/shm` separation
plus `nodev`/`nosuid`/`noexec` across `/home`, `/tmp`, `/var`, `/var/tmp`,
`/var/log`, `/var/log/audit`.

Both failures are expected and documented:

| Rule | Why |
|---|---|
| `grub2_password` | A bootloader password baked into a public image is shared by everyone and does not protect an image whose disk can simply be mounted. Run `grub2-setpassword` after deploying. |
| `accounts_password_last_change_is_in_past` | Build artifact — passwords are set minutes before the audit. Resolved in the shipped image by the seal step. |

## First login

| | |
|---|---|
| Username | `builder` |
| Password | `cis-hardened` |
| root | **locked** — use `sudo` |

The password is **expired on purpose** and must be changed at first login. It is
public until you change it, so change it before exposing the VM to a network.

SSH is restricted to the `wheel` group. Add your accounts to it, or edit
`/etc/ssh/sshd_config.d/49-cis-access.conf`.

## Before production use

1. Change the password (forced), then add an SSH key.
2. `grub2-setpassword` — see the exception above.
3. Configure remote logging if your policy requires it.
4. Re-run the audit yourself:
   ```
   sudo oscap xccdf eval \
     --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
     --report ~/report.html \
     /usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml
   ```

## What is in the image

AIDE baseline built against the shipped state, auditd from first boot, SELinux
enforcing, CIS partition layout, minimal package set, and the guest agent for
its hypervisor. `machine-id` and SSH host keys are cleared, so clones do not
share an identity.

## Limitations

These images are **hardened, not certified**. They are built against a published
benchmark and audited with the standard scanner — that is evidence, not
accreditation. CIS Benchmark documents are not redistributed here; only rule
identifiers and results.
