# Troubleshooting

Hard-won findings, written down so they are not rediscovered the expensive way.

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
| VirtualBox's EFI firmware won't boot the ISO | **Wrong** | EFI boots it fine. `VBoxManage showvminfo` confirmed the ISO on SATA port 1 with the patched plugin, and the guest reached the same kernel stage as BIOS. The "EFI falls through to network boot" reading of `VBox.log` was a misreading of a guest that had *already booted*. **No upstream bug report is warranted.** |
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

### Related upstream work

`packer-plugin-virtualbox` PR
[#192](https://github.com/hashicorp/packer-plugin-virtualbox/pull/192) (attach
ISOs to low SATA ports for EFI guests) is a **real and separate** bug, confirmed
correct. It is not needed by this project, because BIOS uses upstream's default
ports — but it is required for anyone building EFI guests with
`iso_interface = "sata"`.

This project uses BIOS on VirtualBox and EFI on VMware. The kickstart's
`reqpart --add-boot` makes that free: Anaconda creates an ESP under EFI or a
biosboot partition under BIOS, so nothing in the CIS layout depends on firmware.
