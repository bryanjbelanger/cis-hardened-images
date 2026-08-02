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

  if [[ ${PROVISIONER:-kickstart} == autoinstall ]]; then
    local f="build/${tgt}/cidata/user-data"
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
    local f="build/${tgt}/ks/ks.cfg"
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
