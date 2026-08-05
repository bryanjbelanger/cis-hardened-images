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
variable "cd_label" {
  type    = string
  default = "OEMDRV"
  # OEMDRV for EL (Anaconda auto-loads a kickstart from it); CIDATA for Ubuntu
  # (Subiquity's NoCloud datasource).
}
variable "provisioning_dir" {
  type    = string
  default = "ks"
  # "ks" holds ks.cfg; "cidata" holds user-data + meta-data.
}
variable "staged_datastream" {
  type    = string
  default = ""
  # Optional local path to a SCAP datastream uploaded before remediation, for
  # targets whose distro packages lack one (Ubuntu).
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
  ks_dir = "build/${var.target}${var.render_suffix}/${var.provisioning_dir}"
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

  cd_files = ["${local.ks_dir}/"]
  cd_label = var.cd_label

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
  # VRAM. This is the setting that actually mattered. The plugin creates the VM
  # with 4MB, and the Rocky installer hung dead at the same point in EVERY
  # configuration tried — EFI and BIOS, media on SATA and on IDE, e1000 and
  # virtio — roughly 8s into the kernel, no console output and no disk I/O for
  # ten minutes, never reaching Anaconda.
  #
  # Isolated by building a VM by hand with the same disk, media and NIC but
  # 16MB of VRAM: the installer started immediately, printing "X or window
  # manager startup failed, falling back to text mode". Anaconda attempts a
  # graphical install first, and on a 4MB VMSVGA framebuffer that attempt wedges
  # the guest instead of falling back.
  #
  # Earlier hypotheses, all wrong, recorded so they are not retried: VirtualBox's
  # EFI firmware refusing to boot, the SATA/AHCI media interface, the e1000 NIC,
  # and the ISO's SATA port. Verified directly — EFI with the ISO on port 13 and
  # 32MB VRAM boots the graphical installer, which is the exact configuration
  # upstream PR #192 claims cannot boot. See TROUBLESHOOTING.md.
  gfx_vram_size = 32

  # EFI, matching VMware. BIOS was tried while chasing the install hang and it
  # works for EL — the kickstart's `reqpart --add-boot` lets Anaconda create
  # whatever the platform needs — but it CANNOT work for Ubuntu: autoinstall's
  # curtin storage config hardcodes a 512M ESP mounted at /boot/efi, and on a
  # BIOS guest subiquity refuses with
  #     autoinstall config did not create needed bootloader partition
  # then crashes to a recovery shell. Packer then meets the live installer's
  # sshd, which has no builder account, and reports an authentication error —
  # a misleading symptom for a partitioning failure.
  #
  # EFI is safe here despite the earlier dead end: that was the 4MB VRAM bug,
  # not firmware. Verified directly — EFI with the ISO on SATA port 13 and 32MB
  # VRAM boots the graphical installer, which is also why stock upstream port
  # placement is fine and no patched plugin is needed.
  firmware      = "efi"
  iso_interface = "sata"

  cd_files = ["${local.ks_dir}/"]
  cd_label = var.cd_label

  # EL VirtualBox images ship WITHOUT Guest Additions, and there is currently no
  # way around it:
  #   * EL has no packaged Guest Additions — EPEL 9 ships nothing named
  #     virtualbox at all. (Requesting one in the kickstart left Anaconda stuck
  #     at an interactive "missing packages ... ignore?" prompt.)
  #   * Oracle's ISO does not compile against RHEL 9.8's kernel:
  #       fileio-r0drv-linux.c: implicit declaration of 'open_with_fake_path'
  #     RHEL reports 5.14 but carries heavy backports, so VirtualBox's
  #     version-gated compatibility code takes the wrong branch. Forcing it past
  #     -Werror does not help; the symbol genuinely is not there.
  #   * Rocky 9 ships no in-tree module either — drivers/virt/ has only coco and
  #     nitro_enclaves.
  # Consequence: `VBoxManage guestcontrol` does not work on EL VirtualBox images.
  # Drive them over SSH, which is what this build does anyway.
  #
  # Ubuntu is NOT affected — it packages virtualbox-guest-utils in universe, so
  # its VirtualBox images get a working agent through the normal kickstart path.
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

  # Ubuntu's packaged SCAP content may not include this release's datastream,
  # so a verified copy rides along and prepare.sh installs it.
  provisioner "file" {
    source      = var.staged_datastream != "" ? var.staged_datastream : "/dev/null"
    destination = "/tmp/${var.ssg_ds}"
  }

  # No-op on EL (toolchain arrives via kickstart); installs it on Ubuntu, where
  # Subiquity cannot.
  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | sudo -S bash '{{.Path}}'"
    script          = "prepare.sh"
  }

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

  # Site policy AFTER the reboot (apparmor enforce needs the new kernel args)
  # and BEFORE the second remediation, so that pass and the final audit both
  # see it. Without this an Ubuntu build scores 357/5 instead of 360/2.
  provisioner "shell" {
    pause_before    = "45s"
    execute_command = "echo '${var.ssh_password}' | sudo -S bash '{{.Path}}'"
    script          = "site-policy.sh"
  }

  provisioner "shell" {
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
      "cp /root/cis-report.html /tmp/cis-report.html",
      # Guest state behind the rules that are still unexplained. Captured
      # here because sealing locks root and the VM is then destroyed.
      "{ echo '## authselect'; authselect current 2>&1 | head -20; echo; echo '## pam.d/system-auth'; ls -l /etc/pam.d/system-auth; grep -n pam_unix /etc/pam.d/system-auth /etc/pam.d/password-auth 2>&1; echo; echo '## cron'; rpm -q cronie cron 2>&1; systemctl is-enabled crond 2>&1; echo; echo '## aide'; ls -l /var/lib/aide/ 2>&1; } > /tmp/diagnostics.txt 2>&1 || true",
      "chmod a+r /tmp/audit-summary.txt /tmp/cis-report.html /tmp/diagnostics.txt",
    ]
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/audit-summary.txt"
    destination = "${var.output_dir}/${var.vm_name}-${source.type}-audit.txt"
  }

  # The full report, not just the counts. Sealing locks root and the VM is
  # destroyed on success, so a failure that is not explained here can only be
  # explained by rebuilding — which is how a rule failing on one distro but not
  # its sibling stayed unexplained through an entire release cycle.
  provisioner "file" {
    direction   = "download"
    source      = "/tmp/cis-report.html"
    destination = "${var.output_dir}/${var.vm_name}-${source.type}-report.html"
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/diagnostics.txt"
    destination = "${var.output_dir}/${var.vm_name}-${source.type}-diagnostics.txt"
  }

  # Seal, then verify its log, then lock — deliberately three steps. Merging
  # seal and lock once hid a silently-failed AIDE baseline.
  provisioner "shell" {
    # {{.Vars}} is REQUIRED here. Packer substitutes environment_vars only where
    # that placeholder appears; overriding execute_command without it silently
    # drops every variable below, and /etc/cis-image-release shipped with
    # hypervisor/profile/datastream/benchmark all reading "unknown". `sudo -E`
    # does not help — it preserves an environment that was never set. `env`
    # applies them to the script's own process regardless of sudoers SETENV.
    execute_command = "echo '${var.ssh_password}' | sudo -S -E env {{.Vars}} bash -eux '{{.Path}}'"
    script          = "seal.sh"
    # Facts seal.sh cannot discover locally, for /etc/cis-image-release.
    # AUDIT_* are read back out of the audit summary written just above.
    environment_vars = [
      "CIS_PROFILE=${var.cis_profile}",
      "SSG_DS=${var.ssg_ds}",
      "IMAGE_HYPERVISOR=${source.type}",
    ]
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/cis-image-release"
    destination = "${var.output_dir}/${var.vm_name}-${source.type}-release.txt"
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
