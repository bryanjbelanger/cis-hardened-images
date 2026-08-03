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
  local fips_arg=""
  if [[ $fips_eff == yes ]]; then
    fips_arg=" fips=1"
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

  # Two provisioner families, same CIS intent:
  #   kickstart   → EL (Anaconda), delivered on an OEMDRV-labeled ISO
  #   autoinstall → Ubuntu (Subiquity), delivered as user-data + meta-data on a
  #                 CIDATA-labeled ISO, and the installer ISO must ALSO be
  #                 repacked with `autoinstall` on the kernel cmdline (see README).
  if [[ ${PROVISIONER:-kickstart} == autoinstall ]]; then
    mkdir -p "build/${tgt}/cidata"
    # identity.password must be an SHA-512 crypt hash, not plaintext.
    local pw_hash
    pw_hash=$(PW_BUILDER="$PW_BUILDER" .venv/bin/python -c \
      "from passlib.hash import sha512_crypt;import os;print(sha512_crypt.hash(os.environ['PW_BUILDER']))")
    HOSTNAME_V=$HOSTNAME BUILDER_HASH_V=$pw_hash FIPS_V=$fips_arg ROOT_PW_V=$PW_ROOT_BUILD \
    CIS_PROFILE_V=$CIS_PROFILE SSG_DS_V=$SSG_DS STAGE_DS_V=$stage_ds \
    python3 - "$tgt" << 'PYEOF'
import os, sys
tmpl = open("autoinstall.tmpl").read()
for token, env in [("@HOSTNAME@","HOSTNAME_V"),("@BUILDER_PW_HASH@","BUILDER_HASH_V"),
                   ("@FIPS_ARG@","FIPS_V"),("@CIS_PROFILE@","CIS_PROFILE_V"),("@ROOT_PW@","ROOT_PW_V"),
                   ("@SSG_DS@","SSG_DS_V"),("@STAGE_DS@","STAGE_DS_V")]:
    tmpl = tmpl.replace(token, os.environ[env])
tgt = sys.argv[1]
open(f"build/{tgt}/cidata/user-data", "w").write(tmpl)
# NoCloud requires meta-data to exist, even if empty but for instance-id.
open(f"build/{tgt}/cidata/meta-data", "w").write(f"instance-id: {tgt}\nlocal-hostname: {os.environ['HOSTNAME_V']}\n")
print(f"rendered build/{tgt}/cidata/{{user-data,meta-data}}")
PYEOF
    return
  fi

  mkdir -p "build/${tgt}/ks"
  # python replaces tokens verbatim — no sed-escaping pitfalls with URLs/slashes.
  HOSTNAME_V=$HOSTNAME INSTALL_SRC_V=$INSTALL_SRC APPSTREAM_V=$APPSTREAM_URL \
  ROOT_PW_V=$PW_ROOT_BUILD BUILDER_PW_V=$PW_BUILDER \
  HARDEN_V=$harden_block POST_HARDEN_V=$post_harden BASEOS_V=$BASEOS_REPO \
  FIPS_V=$fips_arg \
  python3 - "$tgt" << 'PYEOF'
import os, sys
tmpl = open("ks.cfg.tmpl").read()
for token, env in [("@HOSTNAME@","HOSTNAME_V"),("@INSTALL_SRC@","INSTALL_SRC_V"),
                   ("@APPSTREAM_URL@","APPSTREAM_V"),("@ROOT_PW@","ROOT_PW_V"),
                   ("@BUILDER_PW@","BUILDER_PW_V"),("@HARDEN_BLOCK@","HARDEN_V"),
                   ("@POST_HARDEN@","POST_HARDEN_V"),("@BASEOS_REPO@","BASEOS_V"),
                   ("@FIPS_ARG@","FIPS_V")]:
    tmpl = tmpl.replace(token, os.environ[env])
out = f"build/{sys.argv[1]}/ks/ks.cfg"
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
