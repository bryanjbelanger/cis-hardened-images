# CIS-hardened image build, one template for both hypervisors.
#
# Render the provisioning files first — Packer consumes what render.sh produces:
#   DRIVER=packer ./render.sh <target>          # kickstart with `reboot --eject`
#   packer build -var-file=packer/vars/<target>.pkrvars.hcl packer/
#
# Notes that cost real debugging to learn:
#   * cd_label = OEMDRV is the whole delivery mechanism for EL. Anaconda
#     auto-loads a kickstart from a volume with that label, so NO boot_command
#     and none of its timing fragility. Packer builds that ISO from cd_files.
#   * The kickstart must `reboot --eject`, not `poweroff`: Packer waits for SSH
#     on the INSTALLED system. --eject drops the media so EFI does not boot the
#     installer a second time.
#   * Run with `-on-error=abort` to keep a failed VM for inspection. Nearly
#     every root cause in this project was found by post-mortem on a broken
#     build; the default cleanup would have destroyed the evidence.

variable "target" {
  type = string
}
variable "iso_url" {
  type = string
}
variable "iso_checksum" {
  type = string
}
variable "vm_name" {
  type = string
}
variable "ssg_ds" {
  type = string
}
variable "cis_profile" {
  type = string
}
variable "guest_os_type_vmware" {
  type    = string
  default = "centos9-64"
}
variable "guest_os_type_virtualbox" {
  type    = string
  default = "RedHat9_64"
}
variable "ssh_username" {
  type    = string
  default = "builder"
}
variable "ssh_password" {
  type      = string
  sensitive = true
}
variable "root_password" {
  type      = string
  sensitive = true
}
variable "disk_size_mb" {
  type    = number
  default = 25600
}
variable "memory_mb" {
  type    = number
  default = 4096
}
variable "cpus" {
  type    = number
  default = 2
}
variable "render_suffix" {
  type    = string
  default = ""
}
variable "output_dir" {
  type    = string
  default = "build/packer"
}

locals {
  # Artifact naming contract with consumers (the desktop-hypervisor-mcp image
  # catalog resolves assets by EXACT name inside a release chosen by tag):
  #   * NO date/version in the filename — that goes in the release tag, or
  #     "latest" can never be resolved to a predictable asset.
  #   * hypervisor family in the name — the images genuinely differ (guest
  #     agent), so one release carries both and they must not collide.
  #   * arch suffix so adding arm64 later changes nothing else.
  artifact_vmware     = "cis-${var.target}-vmware-amd64.ova"
  artifact_virtualbox = "cis-${var.target}-virtualbox-amd64.ova"

  # render.sh writes the kickstart here; Packer turns the directory into the
  # OEMDRV ISO itself, so make_iso is no longer needed for EL targets.
  ks_dir = "build/${var.target}${var.render_suffix}/ks"
}

source "vmware-iso" "cis" {
  vm_name              = var.vm_name
  iso_url              = var.iso_url
  iso_checksum         = var.iso_checksum
  guest_os_type        = var.guest_os_type_vmware
  cpus                 = var.cpus
  memory               = var.memory_mb
  disk_size            = var.disk_size_mb
  disk_adapter_type    = "sata"
  network_adapter_type = "vmxnet3"
  firmware             = "efi"

  cd_files = ["${local.ks_dir}/ks.cfg"]
  cd_label = "OEMDRV"

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = "45m" # install + first boot
  ssh_handshake_attempts = 100   # CIS sshd rate-limits (MaxStartups)

  # No shutdown_command: lock-accounts.sh powers the guest off itself, because
  # by then the build password no longer works for sudo.
  shutdown_timeout = "20m"
  output_directory = "${var.output_dir}/${var.vm_name}-vmware"
  headless         = true
}

source "virtualbox-iso" "cis" {
  vm_name              = var.vm_name
  iso_url              = var.iso_url
  iso_checksum         = var.iso_checksum
  guest_os_type        = var.guest_os_type_virtualbox
  cpus                 = var.cpus
  memory               = var.memory_mb
  disk_size            = var.disk_size_mb
  hard_drive_interface = "sata"
  # SATA + EFI. Upstream packer-plugin-virtualbox hardcodes ISO attachment to
  # SATA ports 13/15, which VirtualBox's EFI firmware cannot boot from — black
  # screen, empty disk, SSH timeout at 45 minutes. Requires the patched plugin
  # from bryanjbelanger/packer-plugin-virtualbox (branch fix/efi-sata-iso-ports),
  # which attaches from port 1 for EFI guests while leaving BIOS unchanged.
  # Upstream refs: hashicorp/packer-plugin-virtualbox#39 and #20.
  iso_interface = "sata"
  firmware      = "efi"

  cd_files = ["${local.ks_dir}/ks.cfg"]
  cd_label = "OEMDRV"

  # Guest Additions pull in gcc/make and have no place in a hardened minimal
  # image. Packer reaches the guest over its own NAT port-forward instead.
  guest_additions_mode = "disable"

  # EFI + VirtualBox will not boot the installer unless the DVD is explicitly
  # first in the boot order — the VM sat at a black screen for 35 minutes with
  # a 2MB disk, having never reached a bootloader. The hand-driven build set
  # this with `--boot1 dvd` and worked; Packer does not set it for us.
  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--boot1", "dvd"],
    ["modifyvm", "{{.Name}}", "--boot2", "disk"],
    ["modifyvm", "{{.Name}}", "--boot3", "none"],
    ["modifyvm", "{{.Name}}", "--boot4", "none"],
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = "45m"
  ssh_handshake_attempts = 100

  shutdown_timeout = "20m"
  output_directory = "${var.output_dir}/${var.vm_name}-virtualbox"
  headless         = true
  format           = "ova"
}

build {
  name    = "cis"
  sources = ["source.vmware-iso.cis", "source.virtualbox-iso.cis"]

  # Everything below runs as root inside the installed system. It mirrors the
  # MCP flow exactly, so results stay comparable to the hand-driven baselines.
  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | sudo -S bash -eux '{{.Path}}'"
    # A long oscap run can drop the SSH session — observed as a guest kernel
    # soft lockup ("CPU#1 stuck for 31s [oscap]") when the host was
    # oversubscribed by other VMs. Tolerate it: the post-reboot pass below
    # re-runs remediation and completes anything this pass missed.
    expect_disconnect = true
    inline = [
      "oscap xccdf eval --remediate --profile ${var.cis_profile} --report /root/remediation.html /usr/share/xml/scap/ssg/content/${var.ssg_ds} || [ $? -eq 2 ]",
    ]
  }

  # A reboot between remediation passes: several rules (apparmor, kernel args,
  # crypto policy) only take effect on the next boot.
  provisioner "shell" {
    execute_command   = "echo '${var.ssh_password}' | sudo -S bash -eux '{{.Path}}'"
    inline            = ["systemctl reboot"]
    expect_disconnect = true
  }

  provisioner "shell" {
    pause_before    = "45s"
    execute_command = "echo '${var.ssh_password}' | sudo -S bash -eux '{{.Path}}'"
    inline = [
      "oscap xccdf eval --remediate --profile ${var.cis_profile} --report /root/remediation2.html /usr/share/xml/scap/ssg/content/${var.ssg_ds} || [ $? -eq 2 ]",
    ]
  }

  # Final audit BEFORE sealing — sealing locks root, after which nothing can be
  # inspected. The summary is pulled back to the host as the build's evidence.
  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | sudo -S bash -eux '{{.Path}}'"
    inline = [
      "oscap xccdf eval --profile ${var.cis_profile} --report /root/cis-report.html --results-arf /root/cis-arf.xml /usr/share/xml/scap/ssg/content/${var.ssg_ds} > /root/audit.txt 2>&1 || true",
      "{ echo pass=$(grep '^Result' /root/audit.txt | grep -c pass); echo fail=$(grep '^Result' /root/audit.txt | grep -c fail); echo total=$(grep -c '^Rule' /root/audit.txt); echo mount_rules_passing=$(grep -A1 -E 'partition_for|mount_option' /root/audit.txt | grep '^Result' | grep -c pass); echo FAILURES:; grep -B1 '^Result.*fail' /root/audit.txt | grep '^Rule' | sed 's/.*content_rule_//'; } > /tmp/audit-summary.txt",
      "chmod a+r /tmp/audit-summary.txt /root/cis-report.html",
    ]
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/audit-summary.txt"
    destination = "${var.output_dir}/${var.vm_name}-${source.type}-audit.txt"
  }

  # Seal, then verify its log, then lock — deliberately three steps. Merging
  # seal and lock once hid a silently-failed AIDE baseline.
  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | sudo -S bash -eux '{{.Path}}'"
    script          = "seal.sh"
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/seal.log"
    destination = "${var.output_dir}/${var.vm_name}-${source.type}-seal.log"
  }

  # LAST provisioner. It changes builder's password, which breaks any later
  # sudo using the build password — including Packer's own shutdown_command.
  # So it powers the machine off itself, detached, and we expect the disconnect.
  provisioner "shell" {
    execute_command   = "echo '${var.ssh_password}' | sudo -S bash -eux '{{.Path}}'"
    script            = "lock-accounts.sh"
    expect_disconnect = true
  }

  post-processor "shell-local" {
    only = ["virtualbox-iso.cis"]
    inline = [
      "SRC='${var.output_dir}/${var.vm_name}-virtualbox/${var.vm_name}.ova'",
      "OUT='${var.output_dir}/${local.artifact_virtualbox}'",
      "mv -f \"$SRC\" \"$OUT\"",
      "(cd \"$(dirname \"$OUT\")\" && shasum -a 256 \"$(basename \"$OUT\")\" > \"$(basename \"$OUT\").sha256\")",
      "ls -lh \"$OUT\" | awk '{print \"OVA: \" $5}'",
    ]
  }

  # vmware-iso produces a vmx+vmdk directory; the shippable artifact is an OVA.
  # ovftool ships with Fusion. (virtualbox-iso already emits format = "ova".)
  post-processor "shell-local" {
    only = ["vmware-iso.cis"]
    inline = [
      "OVFTOOL='/Applications/VMware Fusion.app/Contents/Library/VMware OVF Tool/ovftool'",
      "OUT='${var.output_dir}/${local.artifact_vmware}'",
      "rm -f \"$OUT\"",
      "\"$OVFTOOL\" --lax --allowExtraConfig --compress=9 '${var.output_dir}/${var.vm_name}-vmware/${var.vm_name}.vmx' \"$OUT\"",
      "(cd \"$(dirname \"$OUT\")\" && shasum -a 256 \"$(basename \"$OUT\")\" > \"$(basename \"$OUT\").sha256\")",
      "ls -lh \"$OUT\" | awk '{print \"OVA: \" $5}'",
    ]
  }
}
