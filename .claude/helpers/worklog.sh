#!/usr/bin/env bash
# Append one worklog entry.
#   worklog.sh <agent> <detail...>
# e.g. worklog.sh research "compare wake-word engines → proposed ADR in report"
# ponytail: plain >> append, single short line so parallel agents interleave but
# do not corrupt. If entries ever get long enough to tear, add flock.
set -euo pipefail

log="$(git rev-parse --show-toplevel)/docs/worklog.md"
[ $# -ge 2 ] || { echo "usage: worklog.sh <agent> <detail...>" >&2; exit 2; }

agent="$1"; shift
today="$(date +%F)"

grep -qx "## $today" "$log" || printf '\n## %s\n\n' "$today" >> "$log"
printf -- '- %s [%s] %s\n' "$(date +%H:%M)" "$agent" "$*" >> "$log"
