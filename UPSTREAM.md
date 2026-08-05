# Upstream contributions

Fixes found while building this pipeline and sent back to the projects they
belong to.

## packer-plugin-virtualbox — EFI guests cannot boot ISOs on high SATA ports

- **PR**: [hashicorp/packer-plugin-virtualbox#192](https://github.com/hashicorp/packer-plugin-virtualbox/pull/192)
- **Author**: Bryan Belanger
- **Fixes**: [#39](https://github.com/hashicorp/packer-plugin-virtualbox/issues/39) · refs [#20](https://github.com/hashicorp/packer-plugin-virtualbox/issues/20), [#145](https://github.com/hashicorp/packer-plugin-virtualbox/issues/145)
- **Branch**: [`bryanjbelanger/packer-plugin-virtualbox@fix/efi-sata-iso-ports`](https://github.com/bryanjbelanger/packer-plugin-virtualbox/tree/fix/efi-sata-iso-ports)

The builder hardcodes ISO attachment to SATA ports 13 (boot ISO), 14 (guest
additions) and 15 (`cd_files`). VirtualBox's EFI firmware does not find a
bootable device there, so an EFI build with `iso_interface = "sata"` never
boots — black screen, empty disk, `Timeout waiting for SSH`.

Isolated with throwaway VMs, everything else held constant (VirtualBox 7.2.14,
Rocky Linux 9.8 ISO, EFI, 25GB disk at SATA 0):

| ISO attachment | Result |
|---|---|
| SATA port 13 (current) | no boot |
| SATA port 1 | boots |
| IDE device 1 | no boot |
| IDE device 0 | boots |

BIOS boots from port 13 fine, which is why only EFI users hit it. The fix
attaches from port 1 for EFI guests and leaves BIOS on the historical ports, so
existing builds cannot regress. Covered by
`TestStepAttachISOs_EFIUsesLowSATAPorts`.

### Status in this repo

The patched plugin is required for `iso_interface = "sata"` + `firmware = "efi"`
VirtualBox builds. Until the PR merges, install it locally:

```bash
git clone -b fix/efi-sata-iso-ports https://github.com/bryanjbelanger/packer-plugin-virtualbox
cd packer-plugin-virtualbox && go build -o /tmp/pkvbox .
packer plugins install --path /tmp/pkvbox github.com/hashicorp/virtualbox
```

**Known remaining issue, separate from the above**: with the patched plugin the
VM boots, but Anaconda does not start and nothing is written to disk — the
VirtualBox build still times out. Not yet isolated, and not claimed to be fixed
by PR #192. The hand-driven MCP path builds VirtualBox images successfully
(274 pass / 2 fail), so it remains the working route for that hypervisor.
