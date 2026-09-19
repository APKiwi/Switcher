#!/bin/sh
# Exercise Claude payloads and the native Codex apply_patch command payload.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
helper="$root/Scripts/hooks/agent-instruction-guard.pl"
claude_hooks="$root/.claude/settings.json"
codex_hooks="$root/.codex/hooks.json"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
git init -q "$fixture"
printf '# Small\n' > "$fixture/AGENTS.md"
printf '@AGENTS.md\n' > "$fixture/CLAUDE.md"
git -C "$fixture" add .
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
mkdir "$fixture/nested"

pass=0
fail=0

payload_codex() {
  perl -MJSON::PP -e 'print encode_json({tool_name=>"apply_patch",tool_input=>{command=>$ARGV[0]}})' "$1"
}

payload_claude_write() {
  perl -MJSON::PP -e 'print encode_json({tool_name=>"Write",tool_input=>{file_path=>$ARGV[0],content=>$ARGV[1]}})' "$1" "$2"
}

payload_claude_edit() {
  perl -MJSON::PP -e 'print encode_json({tool_name=>"Edit",tool_input=>{file_path=>$ARGV[0],old_string=>$ARGV[1],new_string=>$ARGV[2],replace_all=>JSON::PP::false}})' "$1" "$2" "$3"
}

run_guard() {
  cwd=$1
  payload=$2
  (cd "$cwd" && printf '%s' "$payload" | perl "$helper")
}

expect_decision() {
  label=$1
  expected=$2
  cwd=$3
  payload=$4
  output=$(run_guard "$cwd" "$payload")
  decision=$(printf '%s' "$output" | perl -MJSON::PP -0777 -e '$t=<>; exit 0 unless length $t; $j=decode_json($t); print $j->{hookSpecificOutput}{permissionDecision} // ""')
  if [ "$decision" = "$expected" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL: $label expected '${expected:-quiet}', got '${decision:-quiet}': $output" >&2
    fail=$((fail + 1))
  fi
}

if cmp -s "$claude_hooks" "$codex_hooks"; then
  pass=$((pass + 1))
else
  echo "FAIL: Claude and Codex hook registrations differ" >&2
  fail=$((fail + 1))
fi

large=$(head -c 17000 /dev/zero | tr '\000' x)
expect_decision "Claude Write blocks an oversized root" deny "$fixture" \
  "$(payload_claude_write "$fixture/AGENTS.md" "$large")"
expect_decision "Claude Edit allows a small root edit" '' "$fixture" \
  "$(payload_claude_edit "$fixture/AGENTS.md" Small Smaller)"

patch='*** Begin Patch
*** Add File: AGENTS.override.md
+small
*** End Patch'
expect_decision "Codex Add File allows a small override" '' "$fixture" "$(payload_codex "$patch")"

patch=$(perl -e 'print "*** Begin Patch\n*** Add File: AGENTS.override.md\n+", "x" x 17000, "\n*** End Patch"')
expect_decision "Codex Add File blocks an oversized override" deny "$fixture" "$(payload_codex "$patch")"

padded_patch=$(printf ' \n\t%s\n \t' "$patch")
expect_decision "Codex trims a padded oversized patch command" deny "$fixture" \
  "$(payload_codex "$padded_patch")"

clean_patch='*** Begin Patch
*** Add File: AGENTS.override.md
+small
*** End Patch'
padded_clean=$(printf ' \n\t%s\n \t' "$clean_patch")
expect_decision "Codex trims a padded clean patch command" '' "$fixture" \
  "$(payload_codex "$padded_clean")"

patch='*** Begin Patch
*** Update File: ../AGENTS.md
@@
-# Small
+# Smaller
*** End Patch'
expect_decision "Codex native command works from a nested directory" '' "$fixture/nested" "$(payload_codex "$patch")"

patch='*** Begin Patch
*** Delete File: CLAUDE.md
*** End Patch'
expect_decision "Codex Delete File reduces the budget" '' "$fixture" "$(payload_codex "$patch")"

patch='*** Begin Patch
*** Add File: docs/notes.md
+unrelated
*** End Patch'
expect_decision "Codex ignores unrelated files" '' "$fixture" "$(payload_codex "$patch")"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "agent-instruction-guard.test: $pass passed"
