#!/usr/bin/env bash
# Render ks.cfg for a target: ./render.sh <target|all>
# Targets are targets/*.env; output is build/<target>/ks/ks.cfg (gitignored —
# it contains the plaintext build passwords from local-creds.env).
#
# EL9 targets harden via the Anaconda OSCAP addon; EL10 targets harden in
# %post because RHEL 10 removed oscap-anaconda-addon (and with it the
# `%addon com_redhat_oscap` kickstart syntax).
set -euo pipefail
cd "$(dirname "$0")"

render_one() {
  local tgt=$1
  # Captured BEFORE the target env is sourced, so `FIPS=yes ./render.sh foo`
  # wins over a FIPS= line inside targets/foo.env.
  local fips_cli="${FIPS:-}"
  local envfile="targets/${tgt}.env"
  [[ -f $envfile ]] || { echo "unknown target: $tgt (no $envfile)" >&2; return 1; }
  # shellcheck disable=SC1090
  source "$envfile"
  source local-creds.env

  # FIPS is opt-in: set FIPS=yes in targets/<name>.env for a standing choice,
  # or FIPS=yes ./render.sh <target|all> for a one-off. Off by default — CIS L1
  # does not require it, and it breaks clients that only speak non-approved
  # algorithms.
  local fips_eff="${fips_cli:-${FIPS:-no}}"

  # PROFILE=stig swaps the benchmark. The id is the same plain string in every
  # product's datastream, so it is computed here rather than duplicated into all
  # eight target files. This MUST happen before the templates are rendered: the
  # kickstart runs its own %post remediation, and leaving CIS_PROFILE untouched
  # would harden the guest to CIS in %post and then audit it against STIG.
  if [[ ${PROFILE:-cis} == stig ]]; then
    CIS_PROFILE="xccdf_org.ssgproject.content_profile_stig"
  fi

  # HYPERVISOR selects the guest agent — the daemon each hypervisor's management
  # tooling talks to. Without the right one the MCP server for that hypervisor
  # cannot run guest operations against the image at all, which is the whole
  # point of these builds. Extend this case for new hypervisors; nothing else
  # in the template is hypervisor-specific.
  #
  # VirtualBox note: neither family gets its agent at install time any more.
  # EL cannot have one at all (no packaged Guest Additions, and Oracle's ISO
  # will not build against RHEL 9.8); Ubuntu gets virtualbox-guest-utils
  # post-boot from prepare.sh, because it lives in universe and Subiquity
  # installs `packages:` from the ISO alone. RHEL-family kernels do strip the
  # in-tree vboxguest/vboxsf modules — verified absent on Rocky 9 — so there is
  # no fallback there either. See README and TROUBLESHOOTING.md.
  local guest_pkgs guest_svcs guest_repo=""
  case "${HYPERVISOR:-vmware}" in
    vmware)
      guest_pkgs="open-vm-tools"; guest_svcs="vmtoolsd" ;;
    virtualbox)
      # EL has NO packaged Guest Additions. This previously requested
      # "virtualbox-guest-additions" from EPEL; that package does not exist
      # there (EPEL 9 ships nothing named virtualbox at all), so Anaconda
      # stopped at an interactive "missing packages ... ignore?" prompt that no
      # automated build can answer. Guest Additions are instead built from
      # Oracle's ISO by install-guest-additions.sh after first boot.
      #
      # What the kickstart installs here is only the toolchain that build
      # needs. install-guest-additions.sh removes it again once the modules are
      # built, so the shipped image carries no compiler.
      #
      # No service is enabled here: the vboxadd units do not exist until the
      # ISO installer has run, and naming them now would fail the kickstart.
      if [[ ${PROVISIONER:-kickstart} == autoinstall ]]; then
        # Debian/Ubuntu DO package it — but in UNIVERSE, and Subiquity installs
        # `packages:` from the ISO's own repo alone
        # (deb file:///cdrom <suite> main restricted). A universe package there
        # aborts the whole install with apt exit status 100:
        #   curtin ... 'virtualbox-guest-utils'] returned non-zero exit status 100
        # Same reason the SCAP toolchain lives in prepare.sh. The agent is
        # installed post-boot there instead, where apt has real sources.
        guest_pkgs=""; guest_svcs=""
      else
        # EL gets NOTHING. Building from Oracle's ISO was tried and does not
        # work: the source fails to compile against RHEL 9.8's kernel
        # (implicit declaration of 'open_with_fake_path' — RHEL reports 5.14
        # but is heavily backported, so VirtualBox's version checks take the
        # wrong branch), and Rocky ships no in-tree vboxguest either.
        # EL VirtualBox images are therefore driven over SSH, not guestcontrol.
        guest_pkgs=""; guest_svcs=""
      fi ;;
    qemu|kvm)
      guest_pkgs="qemu-guest-agent"; guest_svcs="qemu-guest-agent" ;;
    hyperv)
      guest_pkgs="hyperv-daemons"; guest_svcs="hypervkvpd hypervvssd hypervfcopyd" ;;
    *)
      echo "unknown HYPERVISOR: ${HYPERVISOR} (vmware|virtualbox|qemu|hyperv)" >&2; return 1 ;;
  esac
  # The autoinstall `packages:` block is emitted WHOLE, because an empty value
  # in a "- item" line renders as a bare "- " — a null list entry, not an empty
  # list. VirtualBox/Ubuntu now has no install-time packages (its agent goes in
  # post-boot), so that case is real.
  local guest_pkgs_yaml=" []"
  if [[ -n $guest_pkgs ]]; then
    guest_pkgs_yaml=""
    while IFS= read -r _p; do
      [[ -n $_p ]] && guest_pkgs_yaml+=$'\n    - '"$_p"
    done <<< "$guest_pkgs"
  fi

  # Carries its OWN leading comma so an empty value cannot leave a trailing one
  # in `services --enabled=...`, which VirtualBox targets now produce (their
  # guest agent is installed after first boot, not by the kickstart).
  local guest_svcs_csv=""
  [[ -n $guest_svcs ]] && guest_svcs_csv=",${guest_svcs// /,}"

  # DRIVER=packer renders a kickstart that reboots into the installed system
  # (Packer provisions over SSH); anything else powers off for the MCP flow.
  local shutdown_stanza="poweroff"
  local autoinstall_shutdown="poweroff"
  if [[ ${DRIVER:-mcp} == packer ]]; then
    shutdown_stanza="reboot --eject"
    autoinstall_shutdown="reboot"
  fi
  # FIPS is enabled in %post with fips-mode-setup, NOT via a fips=1 bootloader
  # arg: with a separate /boot (which the CIS layout mandates) dracut also needs
  # boot=UUID=..., and that UUID does not exist at kickstart-authoring time.
  # fips-mode-setup writes both, installs dracut-fips and rebuilds the initramfs.
  local fips_arg=""
  local fips_post=""
  local fips_post2=""
  if [[ $fips_eff == yes ]]; then
    fips_post="# FIPS 140 mode (FIPS=yes). fips-mode-setup handles dracut-fips, the
# initramfs rebuild, and the fips=1 + boot=UUID= kernel arguments — the latter
# is required because /boot is a separate filesystem, and omitting it makes the
# installed system panic before networking comes up.
fips-mode-setup --enable || echo 'WARNING: fips-mode-setup failed' >&2"
    # CIS remediation sets a DEFAULT-based custom crypto policy, which overwrites
    # the FIPS policy fips-mode-setup installed and leaves the system reporting
    # "Inconsistent state detected". Re-apply the SAME CIS sub-policies on a FIPS
    # base afterwards so both hold. Verified on Rocky 9.
    fips_post2="# Reconcile crypto policy: CIS's custom policy is DEFAULT-based and clobbers
# the FIPS policy set earlier in this %post. Layer the CIS sub-policies onto a
# FIPS base instead, or FIPS reports an inconsistent state.
update-crypto-policies --set FIPS:NO-SHA1:NO-SSHCBC:NO-SSHWEAKCIPHERS:NO-SSHWEAKMACS:NO-WEAKMAC:NO-RPMSHA1 \\
  || update-crypto-policies --set FIPS"
  fi

  # Remediation runs in %post on EVERY target, EL9 included.
  #
  # The Anaconda addon (%addon com_redhat_oscap) is NOT usable here:
  #   - EL10 removed oscap-anaconda-addon outright, and the kickstart syntax
  #     with it;
  #   - EL9 minimal ISOs abort the install with "SCAP Security Guide not found
  #     on the system" — the addon needs SSG content inside the installer
  #     runtime, which only the full DVD image carries.
  # %post remediation needs nothing but the packages we already install, and
  # is verified equivalent: the EL10 build scored 300 pass / 8 fail with all
  # 21 partition and mount-option rules passing, because the CIS partition
  # layout is declared in the kickstart itself rather than retrofitted.
  local harden_block post_harden
  harden_block="# CIS Server L1 remediation runs in %post (see below) on every target —
# the Anaconda OSCAP addon is unavailable on EL10 (removed) and on EL9
# minimal media (no SSG content in the installer runtime)."
  post_harden="# CIS Server L1 remediation: oscap exits 2 when it fixed failing rules —
# that is success here, hence the guard. Rules needing a reboot or a second
# pass are caught by the first-boot audit loop.
oscap xccdf eval --remediate \\
  --profile ${CIS_PROFILE} \\
  --report /root/ks-remediation-report.html \\
  /usr/share/xml/scap/ssg/content/${SSG_DS} || [ \$? -eq 2 ]"


  # SSG_SOURCE=staged: the distro's packaged SCAP content lacks this release's
  # datastream (Ubuntu 24.04's ssg-debderived ships 16.04-22.04 only), so a
  # verified copy rides along on the CIDATA volume and is installed into the
  # image before remediation. =package (default) uses the distro package.
  local stage_ds=""
  if [[ ${SSG_SOURCE:-package} == staged ]]; then
    stage_ds="    - curtin in-target -- mkdir -p /usr/share/xml/scap/ssg/content
    - sh -c \"cp /cdrom/${SSG_DS} /target/usr/share/xml/scap/ssg/content/ || cp /media/*/${SSG_DS} /target/usr/share/xml/scap/ssg/content/\""
  fi

  # Three provisioner families, same CIS intent:
  #   kickstart   → EL (Anaconda), delivered on an OEMDRV-labeled ISO
  #   autoinstall → Ubuntu (Subiquity), delivered as user-data + meta-data on a
  #                 CIDATA-labeled ISO, and the installer ISO must ALSO be
  #                 repacked with `autoinstall` on the kernel cmdline (see README).
  #   preseed     → Debian (debian-installer). d-i has NO volume-label discovery,
  #                 so the preseed is embedded in a repacked ISO and named on the
  #                 kernel cmdline (see repack-iso.sh).
  if [[ ${PROVISIONER:-kickstart} == preseed ]]; then
    local outdir="build/${tgt}${RENDER_SUFFIX:-}/preseed"
    mkdir -p "$outdir"
    OUTDIR_V=$outdir HOSTNAME_V=$HOSTNAME ROOT_PW_V=$PW_ROOT_BUILD BUILDER_PW_V=$PW_BUILDER \
    python3 - "$tgt" << 'PRESEED_EOF'
import os, sys
tmpl = open("preseed.tmpl").read()
for token, env in [("@HOSTNAME@","HOSTNAME_V"),("@ROOT_PW@","ROOT_PW_V"),
                   ("@BUILDER_PW@","BUILDER_PW_V")]:
    tmpl = tmpl.replace(token, os.environ[env])
left = [t for t in ("@HOSTNAME@","@ROOT_PW@","@BUILDER_PW@") if t in tmpl]
if left:
    sys.exit("unsubstituted tokens remain: " + ",".join(left))
out = os.environ["OUTDIR_V"] + "/preseed.cfg"
open(out, "w").write(tmpl)
print(f"rendered {out}")
PRESEED_EOF
    return
  fi

  if [[ ${PROVISIONER:-kickstart} == autoinstall ]]; then
    local outdir="build/${tgt}${RENDER_SUFFIX:-}/cidata"
    mkdir -p "$outdir"
    # identity.password must be an SHA-512 crypt hash, not plaintext.
    local pw_hash
    pw_hash=$(PW_BUILDER="$PW_BUILDER" .venv/bin/python -c \
      "from passlib.hash import sha512_crypt;import os;print(sha512_crypt.hash(os.environ['PW_BUILDER']))")
    OUTDIR_V=$outdir AUTOINSTALL_SHUTDOWN_V=$autoinstall_shutdown HOSTNAME_V=$HOSTNAME BUILDER_HASH_V=$pw_hash FIPS_V=$fips_arg FIPS_POST_V=$fips_post ROOT_PW_V=$PW_ROOT_BUILD GUEST_PKGS_V=$guest_pkgs_yaml \
    CIS_PROFILE_V=$CIS_PROFILE SSG_DS_V=$SSG_DS STAGE_DS_V=$stage_ds \
    python3 - "$tgt" << 'PYEOF'
import os, sys
tmpl = open("autoinstall.tmpl").read()
for token, env in [("@HOSTNAME@","HOSTNAME_V"),("@BUILDER_PW_HASH@","BUILDER_HASH_V"),
                   ("@FIPS_ARG@","FIPS_V"),("@CIS_PROFILE@","CIS_PROFILE_V"),("@ROOT_PW@","ROOT_PW_V"),
                   ("@SSG_DS@","SSG_DS_V"),("@STAGE_DS@","STAGE_DS_V"),("@GUEST_PKGS@","GUEST_PKGS_V"),("@AUTOINSTALL_SHUTDOWN@","AUTOINSTALL_SHUTDOWN_V")]:
    tmpl = tmpl.replace(token, os.environ[env])
tgt = sys.argv[1]
open(os.environ["OUTDIR_V"] + "/user-data", "w").write(tmpl)
# NoCloud requires meta-data to exist, even if empty but for instance-id.
open(os.environ["OUTDIR_V"] + "/meta-data", "w").write(f"instance-id: {tgt}\nlocal-hostname: {os.environ['HOSTNAME_V']}\n")
print(f"rendered build/{tgt}/cidata/{{user-data,meta-data}}")
PYEOF
    return
  fi

  # RENDER_SUFFIX keeps concurrent builds of the SAME target apart. Without it,
  # a fusion and a virtualbox build render to one path and race: the second
  # overwrites the first's kickstart before Packer bakes it into the OEMDRV ISO,
  # and BOTH installs get the wrong guest agent. Verified the hard way.
  local outdir="build/${tgt}${RENDER_SUFFIX:-}/ks"
  mkdir -p "$outdir"
  # python replaces tokens verbatim — no sed-escaping pitfalls with URLs/slashes.
  HOSTNAME_V=$HOSTNAME INSTALL_SRC_V=$INSTALL_SRC APPSTREAM_V=$APPSTREAM_URL \
  ROOT_PW_V=$PW_ROOT_BUILD BUILDER_PW_V=$PW_BUILDER \
  HARDEN_V=$harden_block POST_HARDEN_V=$post_harden BASEOS_V=$BASEOS_REPO \
  OUTDIR_V=$outdir FIPS_V=$fips_arg FIPS_POST_V=$fips_post FIPS_POST2_V=$fips_post2 SHUTDOWN_V=$shutdown_stanza GUEST_PKGS_V=$guest_pkgs GUEST_SVCS_V=$guest_svcs GUEST_SVCS_CSV_V=$guest_svcs_csv GUEST_REPO_V=$guest_repo \
  python3 - "$tgt" << 'PYEOF'
import os, sys
tmpl = open("ks.cfg.tmpl").read()
for token, env in [("@HOSTNAME@","HOSTNAME_V"),("@INSTALL_SRC@","INSTALL_SRC_V"),
                   ("@APPSTREAM_URL@","APPSTREAM_V"),("@ROOT_PW@","ROOT_PW_V"),
                   ("@BUILDER_PW@","BUILDER_PW_V"),("@HARDEN_BLOCK@","HARDEN_V"),
                   ("@POST_HARDEN@","POST_HARDEN_V"),("@BASEOS_REPO@","BASEOS_V"),
                   ("@FIPS_ARG@","FIPS_V"),("@FIPS_POST@","FIPS_POST_V"),("@FIPS_POST2@","FIPS_POST2_V"),("@SHUTDOWN@","SHUTDOWN_V"),("@GUEST_PKGS@","GUEST_PKGS_V"),("@GUEST_SVCS@","GUEST_SVCS_V"),("@GUEST_SVCS_CSV@","GUEST_SVCS_CSV_V"),("@GUEST_REPO@","GUEST_REPO_V")]:
    tmpl = tmpl.replace(token, os.environ[env])
out = os.environ["OUTDIR_V"] + "/ks.cfg"
open(out, "w").write(tmpl)
print(f"rendered {out}")
PYEOF
}

if [[ ${1:-} == all ]]; then
  for f in targets/*.env; do render_one "$(basename "$f" .env)"; done
elif [[ -n ${1:-} ]]; then
  render_one "$1"
else
  echo "usage: $0 <target|all>  (targets: $(ls targets | sed 's/.env//' | tr '\n' ' '))" >&2
  exit 1
fi
