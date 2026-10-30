#!/bin/sh
# Template-managed: canonical copy is game-template/scripts/check-scratch.sh. Do not hand-edit in a game repo:
# change it in the template and re-propagate (scaffold-game-repo skill). Commits are gated by the pre-commit template-sync check.
# check-scratch.sh - keep specs, plans and program state out of the repo. Program state lives
# outside the repository (docs/programs/README.md). Scratch roots are docs/superpowers/ at the repo
# root and any .superpowers/ folder at any depth.
#
#   R1  no tracked file under a scratch root
#   R2  no tracked text names a file under a scratch root. A bare folder mention, a placeholder path
#       (a segment with <, * or YYYY) and the upstream obra/superpowers URL pass.
#   R3  no new doc under docs/ named by date, except a record under docs/verification/ (staged only)
#   R4  no tracked file under docs/programs/ except exact docs/programs/README.md
#
# Two modes, the same split as check-dashes.sh:
#
#   (default)   staged mode - what .githooks/pre-commit runs. R1 on staged additions and changes (so a
#               `git rm --cached` passes), R2 on ADDED lines only, R3 on new paths, R4 on the full index.
#   --tree      whole-tree mode - what CI runs. R1 on every tracked path, R2 on every tracked text file,
#               R4 on every tracked path, including files absent from the working tree.
#
# During a merge, R2 ignores lines already in the same file in any parent, and R3 ignores paths
# already in any parent. Merge parents include HEAD and every entry in MERGE_HEAD.
#
# R2 skips this script, its test, and every pathspec listed in .scratch-check-ignore (one per line,
# blank lines and # comments ignored), for content managed elsewhere such as third-party text.
# Each violation is one stderr line, check-scratch: <path>: <reason>. Exit 0 clean, 1 on a violation,
# 2 on an unknown mode or a git error.
set -eu

mode=${1:-staged}
case "$mode" in
  --tree|staged) ;;
  *)
    echo "check-scratch: unknown mode '$mode' (expected: staged, --tree)" >&2
    exit 2
    ;;
esac

# Where this script lives, resolved before the cd below so a relative $0 still resolves.
self_here=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || self_here=
top=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "check-scratch: not inside a git work tree" >&2
  exit 2
}
cd "$top"

g() { git -c core.quotePath=false "$@"; }
fail=0
report() { echo "check-scratch: $1: $2" >&2; fail=1; }

scratch_paths='^docs/superpowers/|(^|/)\.superpowers/'

# Pathspecs R2 searches: everything, minus the check, its test and the ignore list.
# The check and its test name scratch paths by design. Exclude them wherever this repo keeps them.
top_physical=$(pwd -P)
case "$self_here/" in
  "$top_physical/") self_dir= ;;
  "$top_physical"/*) self_dir=${self_here#"$top_physical"/}/ ;;
  *) self_dir=scripts/ ;;
esac
set -- . ":(exclude)${self_dir}check-scratch.sh" ":(exclude)${self_dir}tests/check-scratch.test.sh"
if [ -f .scratch-check-ignore ]; then
  while IFS= read -r spec || [ -n "$spec" ]; do
    spec=$(printf '%s' "$spec" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$spec" in ''|'#'*) continue ;; esac
    set -- "$@" ":(exclude)$spec"
  done < .scratch-check-ignore
fi

# The one R2 classifier for both modes. Input lines are path:line:text. A reference is superpowers/
# preceded by line start, whitespace, ( [ a quote, a backtick, . ../ or docs/, so obra/superpowers/
# never matches. The path after it is allowed when every segment is empty, a known scratch folder, or
# a placeholder.
classify='
BEGIN {
  n = split("plans specs sdd sdd-archive brainstorm finished sandbox proofs assets", w, " ")
  for (i = 1; i <= n; i++) folder[w[i]] = 1
  lead = " \t([\"`." sprintf("%c", 39)
}
function is_ref(s, at,   c) {
  if (at == 1) return 1
  c = substr(s, at - 1, 1)
  if (index(lead, c) > 0) return 1
  if (c != "/") return 0
  if (at >= 4 && substr(s, at - 3, 3) == "../") return 1
  if (at >= 6 && substr(s, at - 5, 5) == "docs/") return 1
  return 0
}
function allowed(p,   n, i, seg) {
  n = split(p, seg, "/")
  for (i = 1; i <= n; i++) {
    if (seg[i] == "" || seg[i] in folder) continue
    if (index(seg[i], "<") || index(seg[i], "*") || index(seg[i], "YYYY")) continue
    return 0
  }
  return 1
}
{
  if (!match($0, /:[0-9]+:/)) next
  file = substr($0, 1, RSTART - 1)
  line = substr($0, RSTART + 1, RLENGTH - 2)
  text = substr($0, RSTART + RLENGTH)
  sub(/\r$/, "", text)
  off = 0
  while ((i = index(substr(text, off + 1), "superpowers/")) > 0) {
    at = off + i
    off = at + 11
    if (!is_ref(text, at)) continue
    rest = substr(text, at + 12)
    match(rest, "^[-A-Za-z0-9_.<>*/]*")
    p = substr(rest, 1, RLENGTH)
    while (p ~ /[.,:)]$/) p = substr(p, 1, length(p) - 1)
    if (!allowed(p)) printf "check-scratch: %s: line %s names a scratch file, superpowers/%s\n", file, line, p
  }
}'

# Staged additions as path:line:text, numbered by their line in the new file. Context lines advance the
# count too, so the numbers hold even if hunks carry context.
added_lines='
/^diff --git / { hdr = 1; next }
hdr && /^\+\+\+ / { file = substr($0, 7); sub(/\t$/, "", file); next }
/^@@ / {
  hdr = 0
  h = $0
  sub(/^@@ -[0-9,]+ \+/, "", h)
  sub(/[^0-9].*$/, "", h)
  ln = h + 0
  next
}
hdr { next }
/^\+/ { print file ":" ln ":" substr($0, 2); ln++; next }
/^ / { ln++ }'

# Parent grep records are parent:path:line:text, followed by added records marked +:path:line:text.
# Compare full lines at the same path, independent of their line numbers or occurrence counts.
merge_new_lines='
{
  sep = index($0, ":")
  source = substr($0, 1, sep - 1)
  record = substr($0, sep + 1)
  if (!match(record, /:[0-9]+:/)) next
  key = substr(record, 1, RSTART - 1) SUBSEP substr(record, RSTART + RLENGTH)
  if (source == "+") {
    if (!(key in existing)) print record
  } else existing[key] = 1
}'

# report_each <reason>: one violation per path read from stdin.
report_each() {
  while IFS= read -r f; do
    if [ -n "$f" ]; then report "$f" "$1"; fi
  done
}

if [ "$mode" = --tree ]; then
  # R1
  hits=$(g ls-files | grep -E "$scratch_paths" || true)
  report_each "tracked under a scratch folder, which is local only" <<EOF
$hits
EOF

  # R2. git grep exits 1 on no match, so only a higher status is an error.
  rc=0
  refs=$(g -c grep.column=false --no-pager grep -I -n -F --no-color -e superpowers/ -- "$@") || rc=$?
  if [ "$rc" -gt 1 ]; then echo "check-scratch: git grep failed" >&2; exit 2; fi
  out=$(printf '%s\n' "$refs" | awk "$classify")
  if [ -n "$out" ]; then printf '%s\n' "$out" >&2; fail=1; fi


else
  staged=$(g diff --cached --name-only --diff-filter=d)
  merge_parents=
  if g rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    merge_head_file=$(g rev-parse --git-path MERGE_HEAD) || exit 2
    merge_heads=$(cat "$merge_head_file") || exit 2
    merge_parents="HEAD
$merge_heads"
  fi

  # R1
  hits=$(printf '%s\n' "$staged" | grep -E "$scratch_paths" || true)
  report_each "staged under a scratch folder, which is local only" <<EOF
$hits
EOF

  # R2. The diff is captured first so a git error (a bad .scratch-check-ignore entry) cannot pass.
  # --inter-hunk-context=0 keeps a user diff.interHunkContext from fusing the -U0 hunks.
  diff=$(g diff --cached --no-color --no-ext-diff --no-textconv --unified=0 --inter-hunk-context=0 \
    --src-prefix=a/ --dst-prefix=b/ --diff-filter=d -- "$@") || {
    echo "check-scratch: git diff failed" >&2
    exit 2
  }
  added=$(printf '%s\n' "$diff" | awk "$added_lines")
  if [ -n "$merge_parents" ]; then
    parent_refs=$(
      for parent in $merge_parents; do
        rc=0
        refs=$(g -c grep.column=false --no-pager grep -I -n -F --no-color -e superpowers/ "$parent" -- "$@") || rc=$?
        if [ "$rc" -gt 1 ]; then echo "check-scratch: git grep failed" >&2; exit 2; fi
        printf '%s\n' "$refs"
      done
    ) || exit 2
    added=$({
      printf '%s\n' "$parent_refs"
      printf '%s\n' "$added" | sed 's/^/+:/'
    } | awk "$merge_new_lines")
  fi
  out=$(printf '%s\n' "$added" | awk "$classify")
  if [ -n "$out" ]; then printf '%s\n' "$out" >&2; fail=1; fi

  # R3. -M so a rename reads as a rename, not an addition.
  dated=$(g diff --cached --name-only -M --diff-filter=A -- docs \
    | grep -E '^docs/' | grep -vE '^docs/verification/' \
    | grep -E '20[0-9][0-9]-[01][0-9]-[0-3][0-9]' || true)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    in_parent=0
    for parent in $merge_parents; do
      if g cat-file -e "$parent:$f" 2>/dev/null; then in_parent=1; break; fi
    done
    if [ "$in_parent" -eq 0 ]; then report "$f" "new doc named by date, name docs by topic"; fi
  done <<EOF
$dated
EOF


fi

# R4 uses the complete resulting index in both modes. Parent files and unchanged files still count,
# while staged deletions and renames out of docs/programs/ leave no forbidden path.
progs=$(g ls-files -- docs/programs/) || {
  echo "check-scratch: git ls-files failed" >&2
  exit 2
}
while IFS= read -r f; do
  case "$f" in ''|docs/programs/README.md) continue ;; esac
  report "$f" "program state lives outside this repository, read docs/programs/README.md"
done <<EOF
$progs
EOF

exit $fail
