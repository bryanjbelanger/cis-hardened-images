# Troubleshooting

Hard-won findings, written down so they are not rediscovered the expensive way.

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

## AlmaLinux 10 + STIG: audit rules do not load at boot

**Status: unresolved. Alma 10 STIG is NOT publishable. Three hypotheses tested
and eliminated — read this before forming a fourth.**

### Symptom

AlmaLinux 10 STIG scores **370 pass / 100 fail**, of which **79 are
`audit_rules_*`**. Rocky 10 STIG, same EL10 base and the same profile, scores
457/14 with **zero** audit_rules failures. Alma 10 **CIS** is unaffected (302/6).

### What is established

From the build's own diagnostics, not inference:

```
rulesd       = 13 rule files present, written correctly by remediation
augenrules --check = "No change"      # rules.d compiles to audit.rules fine
active_rules = 12                     # kernel has only 12
enabled      = 1                      # -e 2 never applied
```

The rules are correct on disk and absent from the running kernel config. The
audit checks the running config, so they fail. `augenrules --load` run by hand
during the build **succeeds** and reports normal status — and after the next
reboot the kernel is back to 12 rules. So loading works on demand and fails at
boot.

### Eliminated — do not retry these

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Rules never reloaded after remediation | **Wrong** | Added a reboot between remediation and audit. No change: still 370/100. |
| `-e 2` loading mid-sequence and locking the rest | **Wrong** | `augenrules` concatenates lexically and `immutable.rules` did sort 7th of 13, which looked decisive. Renamed it to `zz-immutable.rules` (confirmed last in the listing) and ran `augenrules --load`. Still 370/100, still 12 active. |
| The load itself erroring partway | **Wrong** | `augenrules --load` output shows normal audit status, no rule rejected. |

### Next step

The evidence points at **boot-time** loading specifically. The next diagnostic —
already added — reports `systemctl is-enabled audit-rules` and `auditd`. If
`audit-rules.service` is disabled or masked on Alma 10, nothing loads rules.d at
boot and everything above follows. Check that before anything else.

Note the reboot added while chasing this is worth keeping regardless: auditing
the system as it will actually boot is right on its own merits, and it is what
made the boot-versus-on-demand distinction visible at all.

---

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
