# Plugin requirements. `packer init packer/` installs these.
#
# The VMware plugin now lives in the vmware/ GitHub org (Broadcom maintains it);
# the VirtualBox plugin remains under hashicorp/.
packer {
  required_plugins {
    vmware = {
      version = ">= 2.1.0"
      source  = "github.com/vmware/vmware"
    }
    virtualbox = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/virtualbox"
    }
  }
}
