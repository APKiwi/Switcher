#!/bin/sh
# Keep root instructions within 16 KiB so global and directory guidance still fit.
# Default mode reads staged content. --tree reads the working tree for CI.
set -eu
mode=${1:-staged}
case "$mode" in
  staged|--tree) ;;
  *) echo "check-agent-instructions: expected staged or --tree" >&2; exit 2 ;;
esac
root=$(git rev-parse --show-toplevel)
cd "$root"
total=0
for path in AGENTS.md AGENTS.override.md CLAUDE.md; do
  if [ "$mode" = staged ]; then
    if git cat-file -e ":$path" 2>/dev/null; then
      count=$(git cat-file -s ":$path")
    else
      count=0
    fi
  elif [ -f "$path" ]; then
    count=$(wc -c < "$path" | tr -d '[:space:]')
  else
    count=0
  fi
  total=$((total + count))
done
if [ "$total" -gt 16384 ]; then
  echo "check-agent-instructions: root guidance is $total bytes, limit 16384." >&2
  echo "Move task-specific reference material to linked docs and keep binding rules in the root." >&2
  exit 1
fi
echo "check-agent-instructions: $total / 16384 bytes"
