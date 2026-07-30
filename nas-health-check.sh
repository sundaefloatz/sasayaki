#!/bin/sh
# nas-health-check.sh -- nightly self-check for the always-on NAS replica.
#
# WHY THIS IS REPORT-ONLY, AND DOES NOT REBUILD THE INDEX:
#   The NAS is a Syncthing RECEIVE-ONLY replica. _wiki/audio_index.json is authored on the PC
#   and copied here verbatim, so rebuilding it here would (a) diverge from the PC, (b) get
#   silently overwritten on the next sync, and (c) churn the SHA1(work_id)-keyed thumb cache.
#   The PC's own nightly job (maintain-library.ps1, 03:15) owns rebuilding + repairing.
#   What this box is uniquely good for is answering the question the PC CANNOT answer:
#   "is the copy that's actually serving the dashboard still readable and self-consistent?"
#
# Exit 0 = healthy (advisory notes are fine and expected on a cross-platform mirror).
# Exit 1 = actionable: real corruption, zero-byte media, or index/disk disagreement.
# Alerts on FAILURE ONLY, reusing the existing ntfy topic -- never mints a new one, because a
# new topic is one nobody is subscribed to, i.e. silent.

set -u
# Everything is derived or env-overridable -- no host-specific paths baked in, so this ships
# safely in a public repo and works on any install:
#   APPDIR    defaults to this script's own directory (it lives in the app dir by definition)
#   CONTAINER name of the running core container      (SASA_CONTAINER)
#   BASE      URL the dashboard is served on          (SASA_BASE)
#   ROOT      library root INSIDE the container       (SASA_ROOT)
APPDIR=${SASA_APPDIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
CONTAINER=${SASA_CONTAINER:-sasayaki-app}
BASE=${SASA_BASE:-http://127.0.0.1:8080}
ROOT=${SASA_ROOT:-/media}
LOGDIR="$APPDIR/_jobs"
LOG="$LOGDIR/nas-health-$(date +%Y%m%d-%H%M%S).log"
TOPIC_FILE="$LOGDIR/ntfy_topic.txt"

mkdir -p "$LOGDIR"

{
  echo "nas-health-check  started=$(date -Is)"

  # 1. is the dashboard actually serving?
  CODE=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$BASE/library" || echo 000)
  echo "dashboard /library -> HTTP $CODE"
  [ "$CODE" = "200" ] || { echo "FAIL: dashboard not serving"; exit 1; }

  # 2. does it still return a populated library?
  N=$(curl -s -m 30 "$BASE/library.json" \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
  echo "library.json works -> $N"
  [ "$N" -gt 0 ] 2>/dev/null || { echo "FAIL: library.json empty or unparseable"; exit 1; }

  # 3. integrity of the replica itself (report-only; see header for why no --fix)
  docker exec -e "SASAYAKI_ROOT=$ROOT" "$CONTAINER" \
    python3 "$ROOT/Sasayaki/library_doctor.py" --root "$ROOT"
  DOC=$?
  echo "doctor exit -> $DOC"
  echo "finished=$(date -Is)"
  exit "$DOC"
} >"$LOG" 2>&1

RC=$?

# prune old logs (keep 30) so _jobs doesn't grow without bound
ls -1t "$LOGDIR"/nas-health-*.log 2>/dev/null | tail -n +31 | while read -r f; do rm -f "$f"; done

if [ "$RC" -ne 0 ] && [ -f "$TOPIC_FILE" ]; then
  TOPIC=$(tr -d ' \t\r\n' <"$TOPIC_FILE")
  if [ -n "$TOPIC" ]; then
    SUMMARY=$(grep -E 'FAIL:|actionable issue' "$LOG" | head -3 | tr '\n' ' ')
    curl -s -m 15 \
      -H "Title: Sasayaki NAS health FAILED" \
      -H "Priority: high" \
      -d "$(printf 'NAS self-check failed (exit %s). %s  log: %s' "$RC" "$SUMMARY" "$LOG")" \
      "https://ntfy.sh/$TOPIC" >/dev/null 2>&1
  fi
fi

exit "$RC"
