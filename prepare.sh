#!/usr/bin/env bash
# Pre-remediation preparation, run inside the guest as root.
#
# EL targets install the whole SCAP toolchain during the kickstart, so there is
# nothing to do. Ubuntu CANNOT: Subiquity installs `packages:` from the ISO
# alone (its install-time sources are literally
# `deb [check-date=no] file:///cdrom <suite> main restricted`), so any universe
# package there aborts the install. The toolchain therefore has to arrive here,
# post-boot, where apt has real network sources.
#
# Idempotent and safe to run on any target.
set -uo pipefail
set +e

log() { echo "[prepare] $*"; }

if command -v oscap >/dev/null 2>&1 && ls /usr/share/xml/scap/ssg/content/*-ds.xml >/dev/null 2>&1; then
  log "SCAP toolchain already present — nothing to do (EL path)"
  exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "installing SCAP toolchain from network sources"
  apt-get update -qq

  # oscap's package name differs by release: noble ships openscap-scanner,
  # jammy only has libopenscap8. Try both rather than branching on version.
  for pkg in openscap-scanner libopenscap8; do
    apt-get install -y -qq "$pkg" 2>/dev/null && { log "installed $pkg"; break; }
  done

  # libpam-pwquality is MANDATORY, not optional: without it twelve
  # accounts_password_pam_* rules silently fail to remediate (measured: 17
  # failures instead of 3).
  apt-get install -y -qq libpam-pwquality auditd aide chrony
  log "toolchain: oscap=$(command -v oscap || echo MISSING) aide=$(command -v aide || echo MISSING)"

  # VirtualBox guest agent, here for exactly the same reason as the toolchain
  # above: virtualbox-guest-utils is in universe, and Subiquity's install-time
  # sources are the ISO alone, so requesting it in autoinstall `packages:`
  # aborts the install with apt exit status 100. Post-boot, apt has real
  # sources and it installs normally.
  #
  # Detected from DMI rather than passed in, so this stays correct however the
  # build is driven. EL cannot use this path at all — there is no packaged
  # Guest Additions on EL and Oracle's ISO will not build against RHEL 9.8
  # (see README).
  if grep -qi virtualbox /sys/class/dmi/id/product_name 2>/dev/null \
     || grep -qi virtualbox /sys/class/dmi/id/sys_vendor 2>/dev/null; then
    log "VirtualBox guest detected — installing virtualbox-guest-utils"
    if apt-get install -y -qq virtualbox-guest-utils 2>/dev/null; then
      systemctl enable virtualbox-guest-utils >/dev/null 2>&1
      log "guest agent: $(command -v VBoxService || echo 'VBoxService MISSING')"
    else
      log "WARNING: virtualbox-guest-utils failed to install — guestcontrol will not work"
    fi
  fi

  # Ubuntu's packaged SCAP content does not always carry the datastream for the
  # release you are building (24.04's ssg-debderived shipped 16.04-22.04 only),
  # so the build stages a verified copy at /root/ instead of trusting the repo.
  install -d /usr/share/xml/scap/ssg/content
  for ds in /root/ssg-*-ds.xml /tmp/ssg-*-ds.xml; do
    [ -f "$ds" ] && { mv -f "$ds" /usr/share/xml/scap/ssg/content/; log "staged $(basename "$ds")"; }
  done
  ls /usr/share/xml/scap/ssg/content/*-ds.xml >/dev/null 2>&1 \
    && log "datastreams: $(ls /usr/share/xml/scap/ssg/content/ | tr '\n' ' ')" \
    || log "WARNING: no SCAP datastream present — remediation will fail"
fi
exit 0
