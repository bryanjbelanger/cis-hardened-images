# Troubleshooting

Hard-won findings, written down so they are not rediscovered the expensive way.

---

## Ubuntu CIS: journald rules fail, and the published 360/2 was wrong

**Settled: the rebuilt 356/9 is honest and the published 360/2 was not.
The underlying defect is still open — one attempted fix is in the wrong
place in the sequence.**

### What was proven

A **published** Ubuntu CIS image was booted and inspected directly:

```
/etc/systemd/journald.conf, mtime = build time, unchanged since:
  line 20: ForwardToSyslog=yes     <- ACTIVE
  line 38: #ForwardToSyslog=no     <- commented default
/etc/systemd/journald.conf.d/     : does not exist
systemd-journal-remote            : NOT installed
```

That image's recorded audit is 360 pass / 2 fail and claims
`journald_disable_forward_to_syslog` passes. The shipped system plainly
violates it.

**Why the audit was fooled:** oscap checks journald's RUNNING configuration.
journald had not reloaded its file since remediation, so the audit measured a
daemon whose in-memory state did not match the file it would load at the next
boot. Auditing after a reboot reports the truth — which is why the rebuild says
356/9.

So the reboot did not cause a regression; it exposed one. Any published image
predating it may overstate its score for rules whose checks read running
daemon state rather than files.

### Attempted fix that did NOT work — and why

`site-policy.sh` now sets `ForwardToSyslog=no` and restarts journald. It runs and
logs success, and the rule still fails:

```
[site-policy] journald ForwardToSyslog=no (rsyslog is masked)
ubuntu2404 CIS vmware — 356 pass / 9 fail   (unchanged)
```

**site-policy runs BEFORE the second remediation pass.** Something in that pass
— most plausibly an rsyslog package operation, since Ubuntu's rsyslog is what
sets this value — puts `ForwardToSyslog=yes` back before the audit sees it.

The fix is not wrong, it is mis-sequenced. It needs to run AFTER the final
remediation and before the audit, alongside `dedup-audit-rules.sh`. Not yet
tried.

### Still unexplained

`package_systemd-journal-remote_installed`, `systemd_journal_upload_url` and
`systemd_journal_upload_server_tls` also fail. The package is genuinely not
installed on the shipped image; CIS wants it. Whether remediation attempts the
install and fails, or never attempts it, has not been checked.

---

## VMware: imported OVA will not power on (hardware version 99)

**Not an image defect — an `ovftool` import bug. One line fixes it.**

### Symptom

An imported VM refuses to start. `vmware.log` contains:

```
[msg.upgrade.tooNewCurrentHWVersion] The virtual machine is using a hardware
version that is too new ...
[msg.moduletable.powerOnFailed] Module 'Upgrade' power on failed.
```

`vmrun start` reports only `Error: The operation was canceled`, which says
nothing useful — the real message is in the VM's `vmware.log`.

### Cause

`ovftool` writes `virtualhw.version = "99"` into the `.vmx` it generates on
import. 99 is not a real hardware version, and Fusion refuses it.

The OVA is **not** at fault, which is worth stating because the obvious first
assumption is that the export is wrong:

```
source VM  .vmx : virtualhw.version = "21"
exported OVA/OVF: <VirtualSystemType>vmx-21</VirtualSystemType>
grep -c '99' on the OVF: 0
imported   .vmx : virtualhw.version = "99"   <- introduced here
```

Both the build VM and the OVF agree on 21. Only the import disagrees.

### Fix

```bash
sed -i '' 's/^virtualhw.version = "99"/virtualhw.version = "21"/' <vm>.vmx
```

Verified: a VM that would not power on starts cleanly after this single edit.

### What NOT to do

Do not "fix" the export. Nothing in the pipeline produces 99, so changing the
`ovftool` export flags or rebuilding the images changes nothing — the rebuilt
OVA carries identical OVF metadata and imports to the same broken `.vmx`. That
was the first conclusion reached here, and it was wrong.

Worth re-testing if `--maxVirtualHardwareVersion` on export ever causes ovftool
to map the version correctly on the way back in; until someone demonstrates
that, the import-side edit is the fix.

VirtualBox images never hit this: `virtualbox-iso` writes OVA natively and does
not involve ovftool.

---

## AlmaLinux 10 + STIG: only 12 of ~113 audit rules load

**Partly solved. The load is fixed; the audit score is not. Alma 10 STIG is still
NOT publishable at 370 pass / 100 fail.**

### Root cause of the load failure — found, and fixed

`auditctl` **aborts the entire load** when a rule is already present:

```
Error sending add rule data request (Rule exists)
There was an error in line 17 of /etc/audit/audit.rules
No rules
```

It does not warn and skip. Alma's SSG content emits the same rule into more than
one file under `rules.d`, so twelve rules loaded, line 17 repeated one of them,
and roughly a hundred never reached the kernel. Rocky 10 scores 457/14 from the
identical profile only because its content happens not to emit a duplicate.

`dedup-audit-rules.sh` removes repeated rules across `rules.d` — in `rules.d`,
not in the compiled `audit.rules`, which `augenrules` regenerates from it at
every boot. Measured effect on AlmaLinux 10:

```
rule lines      386 -> 86   (300 duplicates removed)
active rules     12 -> 81
auditd enabled    1 -> 2    (the -e 2 immutable flag now applies)
```

It is **conditional**: it only rewrites `rules.d` when a load is actually
aborting on a duplicate, and leaves a healthy system untouched. Rocky 10 loads
all 113 of its rules with duplicates present, and relocating rules between files
can break checks that look for a rule in a specific file — so a working target
must not be "fixed".

### What is still wrong

Despite 81 rules active and the immutable flag applied, the audit is **unchanged
at 370/100 with the same 79 `audit_rules_*` failures**. Rocky 10 has 113 active
and zero such failures. So the remaining gap is not the load abort:

* Alma reaches 81 active rules against Rocky's 113 — roughly 32 short.
* Failures include rules that ought to be satisfiable, such as
  `audit_rules_immutable` (which wants `-e 2`, and `auditctl -s` now reports
  `enabled 2`).

Two candidates, neither tested:

1. Alma's remediation emits fewer distinct rules than its own profile checks for
   — an upstream content mismatch.
2. The checks inspect specific FILES rather than the running configuration, and
   deduplication moved a rule into a different file from the one being checked.

Distinguishing them needs the full `auditctl -l` output and the per-rule OVAL
detail from the report, neither of which is captured yet.

### Diagnostic lesson worth keeping

This took four wrong hypotheses because the load ran as
`augenrules --load 2>&1 | tail -3`. The rejection prints BEFORE the trailing
status block, so the one line naming the fault was discarded every time, while
every other signal looked healthy — rules present on disk, `augenrules --check`
reporting "No change". **Replay the load and keep all of its output** before
theorising about anything else.

## VirtualBox on EL: Guest Additions will not compile

**Status: blocked upstream, and expected to un-block on its own. Re-test when
either side moves — see the retest condition below.**

### Symptom

`VBoxLinuxAdditions.run` exits non-zero, `vboxguest` never loads, and
`/var/log/vboxadd-setup.log` contains:

```
fileio-r0drv-linux.c:162:30: error: implicit declaration of function
'open_with_fake_path' [-Werror=implicit-function-declaration]
```

### Cause — an off-by-one in a version guard, not neglect

From the GA 7.2.14 source (`vboxguest/r0drv/linux/fileio-r0drv-linux.c`):

```c
# if RTLNX_VER_MIN(6,10,0)
      kernel_file_open(&Path, fOpenMode, current_cred());
# elif RTLNX_VER_MIN(6,5,0) || RTLNX_RHEL_RANGE(9,9, 9,99)
      kernel_file_open(&Path, fOpenMode, d_inode(Path.dentry), current_cred());
# elif RTLNX_VER_MIN(4,19,0)
      open_with_fake_path(&Path, fOpenMode, d_inode(Path.dentry), current_cred());
```

Oracle does support EL — this source carries 335 RHEL-specific guards. But the
guard here starts at **RHEL 9.9**, and we build on **9.8**, so compilation falls
through to the generic ≥4.19 branch and calls a function the kernel no longer
has.

`RTLNX_RHEL_RANGE` reads `RHEL_MAJOR`/`RHEL_MINOR` — the *point release*. Red Hat
backports API changes into z-stream kernels **within** a point release, and
`5.14.0-687.33.1.el9_8` is a late 9.8 build that already carries the
`kernel_file_open` change Oracle expected in 9.9. A version-number comparison
cannot see a mid-release backport, which is why nothing on our side fixes it: no
package is missing, and forcing past `-Werror` only moves the failure to module
load time on an undefined symbol.

Oracle Linux does not hit this because it defaults to UEK, a much newer
mainline-based kernel that takes the `RTLNX_VER_MIN(6,10,0)` branch and never
reaches this code — so a late RHCK 9.8 regression is not in their test path.

### Everything else is closed too

* EPEL 9 ships nothing named `virtualbox` — there is no packaged Guest Additions
  on EL. A kickstart requesting one leaves Anaconda at an interactive
  "missing packages … ignore?" prompt that no automated build can answer.
* Rocky 9 has no in-tree module: `drivers/virt/` contains only `coco` and
  `nitro_enclaves` (checked inside a guest, not assumed).

### Consequence and retest condition

EL VirtualBox images ship **without a guest agent**, so `VBoxManage
guestcontrol` does not work against them — drive them over SSH. Ubuntu is
unaffected; it packages `virtualbox-guest-utils` in universe.

Re-test and re-enable when **either** is true:

* the EL target moves to **9.9 or later** — it then satisfies
  `RTLNX_RHEL_RANGE(9,9, 9,99)` and should compile unchanged; or
* a **newer Guest Additions** release moves that lower bound to 9.8.

The scope is narrower than "EL VirtualBox has no agent": it is *Rocky/Alma 9.8
on a late z-stream kernel, with GA 7.2.14*.

---

## VirtualBox: the installer hangs and the build times out waiting for SSH

**Fix: give the guest more VRAM.** `gfx_vram_size = 32` in the `virtualbox-iso`
source. That is the whole fix.

### Symptom

The build reaches `Waiting for SSH to become available...` and never gets
further, failing 45 minutes later. Inside the guest:

* the VDI stays at 2 MB — nothing is ever installed
* the console freezes ~8 seconds into the kernel, last lines being
  `Reached target Path Units` and (on e1000) two `Unmaintained driver is
  detected` warnings
* `VBox.log` shows storage controllers reset and `NAT: Link up`, then nothing
  but `ip6_icmp: MTU is too small...` noise forever
* **no** dracut timeout, **no** emergency shell, no error of any kind — a hard
  freeze, not a wait

### Cause

The plugin creates the VM with **4 MB of VRAM**. Anaconda attempts a *graphical*
install first, and on a 4 MB VMSVGA framebuffer that attempt wedges the guest
instead of falling back to text mode. With enough VRAM it falls back cleanly and
prints:

```
X or window manager startup failed, falling back to text mode.
```

That message is the tell. A working VirtualBox build shows it; the hang is what
happens when the fallback cannot run.

### What it is NOT — do not re-investigate these

All three were plausible, all three were tested, all three were wrong. The hang
is identical in every one of these configurations, which is itself the clue: the
cause is common to all of them.

| Suspected | Verdict | Evidence |
|---|---|---|
| VirtualBox's EFI firmware won't boot the ISO | **Wrong** | EFI boots it fine. Verified directly: EFI + ISO on SATA port 13 + 32 MB VRAM boots the *graphical* installer. The "EFI falls through to network boot" reading of `VBox.log` was a misreading of a guest that had *already booted*. **No upstream bug report is warranted.** |
| The SATA port the ISO is attached to (the premise of PR #192) | **Wrong** | See below — the port is not the variable, VRAM is. |
| The SATA/AHCI interface for installer media | **Wrong** | Identical hang with media on IDE. |
| The e1000 NIC (RHEL 9 calls it unmaintained) | **Wrong** | The hand-built VM that worked used e1000. The warnings are noise that merely happen to be the last thing printed. |

### How it was isolated — reuse this technique

Changing Packer settings one at a time produced three wrong answers, because
every configuration failed identically. What worked was going the other
direction:

1. Build a VM **by hand** through the VirtualBox MCP (`vm_lifecycle create`,
   `storage add_controller` / `create_medium` / `attach`, `vm_config modify`
   for boot order, `vm_lifecycle start`).
2. Boot the plain installer ISO — no kickstart needed. Reaching the Anaconda
   welcome screen is a sufficient signal.
3. Screenshot it: `execute_command controlvm <vm> screenshotpng <path>`, then
   read the PNG.
4. Diff that VM's `showvminfo` against the one Packer built.

The hand-built VM booted Anaconda immediately, and the config diff had exactly
one meaningful entry: VRAM 16 MB vs 4 MB.

**The screenshot is the highest-value diagnostic in this whole class of
problem.** Packer only reports "no SSH"; the guest console says what actually
happened. Reach for it early rather than after three hypotheses.

### Related upstream work: PR #192 rests on this same misdiagnosis

`packer-plugin-virtualbox` PR
[#192](https://github.com/hashicorp/packer-plugin-virtualbox/pull/192) attaches
ISOs to low SATA ports for EFI guests, on the premise that VirtualBox's EFI
cannot boot from the high ports. **That premise does not hold once VRAM is
adequate.**

Controlled test, everything else constant (VirtualBox 7.2.14, Rocky 9.8 ISO,
EFI, 25 GB disk at SATA port 0):

| Firmware | ISO port | VRAM | Result |
|---|---|---|---|
| EFI | 1 | 4 MB | hangs |
| BIOS | 13 | 4 MB | hangs |
| BIOS | 1 | 16 MB | boots (text mode) |
| EFI | **13** | 32 MB | **boots (graphical)** |

Port 13 under EFI — the exact case the PR calls unbootable — boots fine. The
PR's own wording describes the failure as *"no boot, blank framebuffer"*, which
is the VRAM symptom, not a boot-device symptom. The likely confound is that the
failing case was tested on a Packer-created VM (4 MB VRAM) and the working case
on a hand-made VM (16 MB default), with the difference attributed to the port.

The PR should be withdrawn or rewritten. VRAM is the discriminator; the ISO's
SATA port is not.

This project uses BIOS on VirtualBox and EFI on VMware. The kickstart's
`reqpart --add-boot` makes that free: Anaconda creates an ESP under EFI or a
biosboot partition under BIOS, so nothing in the CIS layout depends on firmware.
