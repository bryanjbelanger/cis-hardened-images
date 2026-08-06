target       = "debian12"
vm_name      = "cis-debian12"
# The REPACKED installer ISO, not Debian's original. debian-installer has no
# volume-label discovery, so the preseed is embedded in the ISO root and named
# on the kernel command line. Produce it with:
#
#   ./render.sh debian12
#   ./repack-iso.sh build/debian12-netinst.iso \
#       build/debian12/installer-preseed.iso \
#       "auto=true priority=critical preseed/file=/cdrom/preseed.cfg" \
#       build/debian12/preseed/preseed.cfg
#
# then set iso_checksum below to the repacked file's sha256.
iso_url      = "file:///Users/bryanbelanger/Projects/cis-hardened-images/build/debian12/installer-preseed.iso"
iso_checksum = "none"
ssg_ds       = "ssg-debian12-ds.xml"
# Debian uses Ubuntu's profile id, not EL's cis_server_l1.
cis_profile = "xccdf_org.ssgproject.content_profile_cis_level1_server"

guest_os_type_vmware     = "debian12-64"
guest_os_type_virtualbox = "Debian_64"

ssh_password  = "aMHJD7RVattRSAdna7E2"
root_password = "HYsqyxMPqvvY8isg0fRZ"
