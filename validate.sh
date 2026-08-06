#!/usr/bin/env bash
# Validate every rendered provisioning file: ./validate.sh [target|all]
#
#   kickstart   → ksvalidator against the target's EL syntax version (real
#                 grammar validation from pykickstart).
#   autoinstall → YAML parse + structural checks. NOTE this is weaker than
#                 ksvalidator: Subiquity's authoritative schema check only runs
#                 on an Ubuntu host (`subiquity-server --autoinstall-schema`),
#                 so a rendered autoinstall file is only proven correct by an
#                 actual build.
set -euo pipefail
cd "$(dirname "$0")"

fail=0

check_one() {
  local tgt=$1
  # shellcheck disable=SC1090
  source "targets/${tgt}.env"

  if [[ ${PROVISIONER:-kickstart} == preseed ]]; then
    local f="build/${tgt}${RENDER_SUFFIX:-}/preseed/preseed.cfg"
    [[ -f $f ]] || { echo "✗ $tgt: $f not rendered"; return 1; }
    # There is no offline grammar checker for preseed the way pykickstart is for
    # kickstart, so this checks the things that have actually broken builds:
    # unsubstituted tokens, a missing partman recipe, and the CIS mount options.
    PRESEED_F="$f" TGT="$tgt" python3 << 'PRESEED_VAL'
import os, re, sys
f, tgt = os.environ["PRESEED_F"], os.environ["TGT"]
text = open(f).read()
problems = []

left = re.findall(r"@[A-Z_]+@", text)
if left:
    problems.append("unsubstituted tokens: " + ",".join(sorted(set(left))))

for req in ("partman-auto/expert_recipe", "passwd/username", "netcfg/get_hostname",
            "partman/confirm", "debian-installer/add-kernel-opts"):
    if req not in text:
        problems.append("missing directive: " + req)

# The CIS layout is the point of the recipe — check every filesystem is there.
for mp in ("/boot", "/home", "/tmp", "/var", "/var/tmp", "/var/log", "/var/log/audit"):
    if "mountpoint{ %s }" % mp not in text:
        problems.append("recipe has no mountpoint for " + mp)

# noexec/nosuid/nodev must survive onto the right filesystems.
for mp, opts in (("/tmp", ("nodev","nosuid","noexec")),
                 ("/var/tmp", ("nodev","nosuid","noexec")),
                 ("/var/log", ("nodev","nosuid","noexec")),
                 ("/var/log/audit", ("nodev","nosuid","noexec")),
                 ("/home", ("nodev","nosuid"))):
    seg = text.split("mountpoint{ %s }" % mp)
    if len(seg) < 2:
        continue
    window = seg[1][:400]
    for o in opts:
        if "options/%s{" % o not in window:
            problems.append("%s missing %s" % (mp, o))

if problems:
    print("✗ %s preseed:" % tgt)
    for p in problems:
        print("    - " + p)
    sys.exit(1)
print("✓ %s preseed: %d directives, CIS layout and mount options present"
      % (tgt, len(re.findall(r"^d-i ", text, re.M))))
PRESEED_VAL
    return $?
  fi

  if [[ ${PROVISIONER:-kickstart} == autoinstall ]]; then
    local f="build/${tgt}${RENDER_SUFFIX:-}/cidata/user-data"
    [[ -f $f ]] || { echo "✗ $tgt: not rendered ($f missing)"; fail=1; return; }
    if USER_DATA="$f" .venv/bin/python - << 'PYEOF'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["USER_DATA"]))
ai = (d or {}).get("autoinstall")
problems = []
if ai is None:
    problems.append("no top-level 'autoinstall' key")
else:
    if ai.get("version") != 1:
        problems.append(f"version is {ai.get('version')!r}, expected 1")
    for k in ("identity", "storage", "packages", "late-commands"):
        if k not in ai:
            problems.append(f"missing '{k}'")
    pw = ai.get("identity", {}).get("password", "")
    if not str(pw).startswith("$6$"):
        problems.append("identity.password is not an SHA-512 crypt hash")
    if "@" in open(os.environ["USER_DATA"]).read().replace("@reboot", ""):
        leftovers = [t for t in ("@HOSTNAME@","@BUILDER_PW_HASH@","@FIPS_ARG@",
                                 "@CIS_PROFILE@","@SSG_DS@")
                     if t in open(os.environ["USER_DATA"]).read()]
        if leftovers:
            problems.append(f"unreplaced tokens: {', '.join(leftovers)}")
    # every CIS mount that must carry options
    want = {"/home": "nodev,nosuid", "/tmp": "nodev,nosuid,noexec",
            "/var": "nodev,nosuid", "/var/tmp": "nodev,nosuid,noexec",
            "/var/log": "nodev,nosuid,noexec", "/var/log/audit": "nodev,nosuid,noexec"}
    mounts = {m.get("path"): m.get("options", "")
              for m in ai.get("storage", {}).get("config", [])
              if m.get("type") == "mount"}
    for path, opts in want.items():
        if path not in mounts:
            problems.append(f"no mount for {path}")
        elif set(mounts[path].split(",")) != set(opts.split(",")):
            problems.append(f"{path} options {mounts[path]!r} != {opts!r}")
if problems:
    print("; ".join(problems), file=sys.stderr)
    sys.exit(1)
PYEOF
    then echo "✓ $tgt (autoinstall: YAML + CIS mount options)"
    else echo "✗ $tgt"; fail=1
    fi
  else
    local f="build/${tgt}${RENDER_SUFFIX:-}/ks/ks.cfg"
    [[ -f $f ]] || { echo "✗ $tgt: not rendered ($f missing)"; fail=1; return; }
    if .venv/bin/ksvalidator -v "RHEL${EL_MAJOR}" "$f" > /dev/null 2>&1; then
      echo "✓ $tgt (kickstart: RHEL${EL_MAJOR} syntax)"
    else
      echo "✗ $tgt"; .venv/bin/ksvalidator -v "RHEL${EL_MAJOR}" "$f" 2>&1 | tail -3; fail=1
    fi
  fi
}

if [[ ${1:-all} == all ]]; then
  for f in targets/*.env; do check_one "$(basename "$f" .env)"; done
else
  check_one "$1"
fi
exit $fail
