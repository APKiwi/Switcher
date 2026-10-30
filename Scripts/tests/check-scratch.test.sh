#!/bin/sh
# Template-managed: canonical copy is game-template/scripts/tests/check-scratch.test.sh. Do not hand-edit in a game repo:
# change it in the template and re-propagate (scaffold-game-repo skill). Commits are gated by the pre-commit template-sync check.
# Exercises every rule and mode of check-scratch.sh against throwaway git repos in a temp dir.
#
# The check runs on every commit and in CI, in every repo that carries it, so both directions matter:
# a scratch file or a link into scratch must fail, and the legitimate text around the rule (bare folder
# mentions, placeholder paths, the upstream obra/superpowers URL) must pass. Each case gets a fresh repo
# so no case leans on another's state.
#
# Run it from anywhere:  sh scripts/tests/check-scratch.test.sh [script-path]
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT=${1:-$here/../check-scratch.sh}
case "$SCRIPT" in /*) ;; *) SCRIPT=$(CDPATH= cd -- "$(dirname -- "$SCRIPT")" && pwd)/$(basename -- "$SCRIPT") ;; esac

if [ ! -f "$SCRIPT" ]; then
  echo "check-scratch.test: script under test not found at $SCRIPT" >&2
  exit 2
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
OUTFILE="$TMPROOT/out"

pass=0
fail=0
check() { # name, expected exit, actual exit
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok    $1"
  else fail=$((fail+1)); echo "  FAIL  $1 (expected exit $2, got $3)"; sed 's/^/        /' "$OUTFILE"; fi
}
run() { set +e; sh "$SCRIPT" "$@" >"$OUTFILE" 2>&1; rc=$?; set -e; return 0; }
# said <text>: keep rc only when the output carries the exact text, so a case can pin a message too.
said() { if ! grep -qF -- "$1" "$OUTFILE"; then rc="$rc, without '$1'"; fi; }
newrepo() {
  mkdir -p "$1"; cd "$1"; git init -q .
  git config user.email t@t.t; git config user.name t
  git config commit.gpgsign false; git config core.autocrlf false; git config core.safecrlf false
}
commit() { git add -A; git commit -q -m "$1"; }
# A fresh repo per case, with the ignore rules a real repo carries and one clean committed file.
case_no=0
fresh() {
  case_no=$((case_no+1))
  newrepo "$TMPROOT/case$case_no"
  printf '.superpowers/\ndocs/superpowers/\n' > .gitignore
  printf '# repo\n\nNothing to see.\n' > README.md
  commit init
}
# put <path> <printf format> [args]: write a file, creating its folder.
put() { p=$1; shift; mkdir -p "$(dirname -- "$p")"; printf "$@" > "$p"; }

echo "== tree mode, tracked scratch (R1) =="
fresh; run --tree
check tree_clean_repo_passes 0 "$rc"

fresh; put docs/superpowers/plans/a.md 'plan\n'; git add -f docs/superpowers/plans/a.md; run --tree
check tree_tracked_docs_superpowers_file_fails 1 "$rc"

fresh; put tools/x/.superpowers/sdd/p.md 'ledger\n'; git add -f tools/x/.superpowers/sdd/p.md; run --tree
check tree_tracked_nested_dot_superpowers_file_fails 1 "$rc"

echo "== tree mode, references (R2) =="
fresh; put docs/a.md 'See the [plan](superpowers/plans/2026-10-04-x.md).\n'; git add docs/a.md; run --tree
check tree_link_to_plan_file_fails 1 "$rc"

fresh; put docs/a.md 'Inputs are fixed (../superpowers/specs/a-design.md#inputs).\n'; git add docs/a.md; run --tree
check tree_relative_parent_link_fails 1 "$rc"

fresh; put docs/a.md 'https://github.com/APKiwiOrg/game-template/blob/main/docs/superpowers/plans/x.md\n'
git add docs/a.md; run --tree
check tree_github_blob_url_fails 1 "$rc"

fresh; put docs/a.md 'The ledger is in `.superpowers/sdd/2026-10-23-class-m2/`.\n'; git add docs/a.md; run --tree
check tree_specific_ledger_dir_fails 1 "$rc"

fresh; put docs/a.md 'Save frames in the worktree'"'"'s `.superpowers/` folder and plans in docs/superpowers/plans/.\n'
git add docs/a.md; run --tree
check tree_bare_folder_mentions_pass 0 "$rc"

fresh; put docs/a.md 'Name it docs/superpowers/plans/YYYY-MM-DD-<topic>.md, or match docs/superpowers/specs/*.md.\n'
git add docs/a.md; run --tree
check tree_placeholder_paths_pass 0 "$rc"

fresh; put docs/a.md 'Upstream is https://github.com/obra/superpowers/blob/main/x.md here.\n'; git add docs/a.md; run --tree
check tree_upstream_obra_url_passes 0 "$rc"

fresh; put .scratch-check-ignore '# managed through the gateway\nmemory/store/\n'
put memory/store/n.md 'Old ledger at .superpowers/sdd/x.md.\n'; git add -A; run --tree
check tree_ignore_file_skips_pathspec 0 "$rc"

fresh; put .scratch-check-ignore '# managed through the gateway\r\nmemory/store/\r\n'
put memory/store/n.md 'Old ledger at .superpowers/sdd/x.md.\n'; git add -A; run --tree
check tree_crlf_ignore_file_skips_pathspec 0 "$rc"

fresh; put art/scene.blend 'BLENDER\000\001\002 .superpowers/sdd/frames/x.png \000\n'; git add art/scene.blend; run --tree
check tree_binary_file_skipped 0 "$rc"

fresh; put docs/a.md 'Intro.\r\nSee the [plan](superpowers/plans/2026-10-04-x.md).\r\n'; git add docs/a.md; run --tree
check tree_crlf_reference_still_fails 1 "$rc"

echo "== tree mode, program files (R4) =="
fresh; put docs/programs/x.md '# x\n\n## Goal\n\nGoal.\n\n## Milestones\n\nNone.\n\n## Next step\n\nContinue.\n'
git add -A; run --tree
said 'program state lives outside this repository, read docs/programs/README.md'
check tree_program_file_fails 1 "$rc"

fresh; put 'docs/programs/archive/old program.md' '# Program\n'; git add -A; run --tree
said 'program state lives outside this repository, read docs/programs/README.md'
check tree_nested_program_file_fails 1 "$rc"

fresh; put docs/programs/state.json '{"status":"Active"}\n'; git add -A; run --tree
said 'program state lives outside this repository, read docs/programs/README.md'
check tree_non_markdown_program_file_fails 1 "$rc"

fresh; put docs/programs/x-design.md '# Design\n'; git add -A; run --tree
said 'program state lives outside this repository, read docs/programs/README.md'
check tree_program_design_file_fails 1 "$rc"

fresh; put docs/programs/archive/README.md '# Old programs\n'; git add -A; run --tree
said 'program state lives outside this repository, read docs/programs/README.md'
check tree_nested_readme_fails 1 "$rc"

fresh; put docs/programs/x.md '# Program\n'; commit program
rm docs/programs/x.md; run --tree
said 'program state lives outside this repository, read docs/programs/README.md'
check tree_missing_working_copy_fails 1 "$rc"

fresh; put docs/programs/README.md '# Programs\r\n'; git add -A; run --tree
check readme_only_passes 0 "$rc"
run
check staged_readme_only_passes 0 "$rc"

echo "== staged mode =="
fresh; put docs/superpowers/plans/a.md 'plan\n'; git add -f docs/superpowers/plans/a.md; run
check staged_force_add_scratch_fails 1 "$rc"

fresh; put docs/superpowers/plans/a.md 'plan\n'; git add -f docs/superpowers/plans/a.md; git commit -q -m scratch
git rm -q --cached docs/superpowers/plans/a.md; run
check staged_rm_cached_scratch_passes 0 "$rc"

fresh; put docs/a.md 'See the [plan](superpowers/plans/2026-10-04-x.md).\n'; git add docs/a.md; run
check staged_added_reference_fails 1 "$rc"

fresh; put 'docs/art notes/a.md' 'See the [plan](superpowers/plans/2026-10-04-x.md).\n'; git add -A; run
said 'check-scratch: docs/art notes/a.md: line 1 names a scratch file'
check staged_path_with_space_reference_fails 1 "$rc"

fresh; put docs/a.md 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n'; commit lines; git config diff.interHunkContext 5
put docs/a.md 'l1\n[p](superpowers/plans/a.md)\nl3\nl4\nl5\nl6\n[p](superpowers/plans/b.md)\nl8\n'; git add -A; run
said 'check-scratch: docs/a.md: line 7 names a scratch file, superpowers/plans/b.md'
check staged_inter_hunk_context_keeps_line_numbers 1 "$rc"

fresh; put .scratch-check-ignore '../outside\n'; commit ignore
put b.md 'See the [plan](superpowers/plans/2026-10-04-x.md).\n'; git add b.md; run
check staged_bad_ignore_entry_exits_2 2 "$rc"

fresh; put docs/a.md 'See the [plan](superpowers/plans/2026-10-04-x.md).\n'; commit old
printf 'A clean new line.\n' >> docs/a.md; git add docs/a.md; run
check staged_existing_reference_in_touched_file_passes 0 "$rc"

fresh; put docs/design/FOO-2026-10-25.md '# foo\n'; git add -A; run
check staged_new_dated_design_doc_fails 1 "$rc"

fresh; put docs/verification/2026-10-25-x.md '# measured\n'; git add -A; run
check staged_dated_verification_record_passes 0 "$rc"

fresh; put docs/design/FOO-2026-10-25.md '# foo\n\nA design that has been here a while.\n'; commit dated
mkdir -p docs/archive; git mv docs/design/FOO-2026-10-25.md docs/archive/FOO-2026-10-25.md; run
check staged_rename_of_dated_doc_passes 0 "$rc"

fresh; put docs/programs/x.md '# Program\n'; git add -A; run
said 'program state lives outside this repository, read docs/programs/README.md'
check staged_program_file_fails 1 "$rc"

fresh; put docs/programs/x.md '# Program\n'; commit program
put unrelated.txt 'Unrelated change.\n'; git add unrelated.txt; run
said 'program state lives outside this repository, read docs/programs/README.md'
check staged_unrelated_change_cannot_grandfather_program_fails 1 "$rc"

fresh; put notes.md '# Program\n'; commit notes
mkdir -p docs/programs/archive; git mv notes.md 'docs/programs/archive/old program.json'; run
said 'program state lives outside this repository, read docs/programs/README.md'
check staged_program_rename_fails 1 "$rc"

fresh; put docs/programs/x.md '# Program\n'; commit program
git mv docs/programs/x.md notes.md; run
check staged_program_rename_out_passes 0 "$rc"

fresh; put docs/programs/x.md '# Program\n'; commit program
git rm -q docs/programs/x.md; run
check staged_program_delete_passes 0 "$rc"

echo "== staged merge mode =="
# Each case branches before main's changes, then leaves a real merge pending in the index.
merge_main() {
  git checkout -q topic
  put topic.txt 'Topic work.\n'; commit topic
  git merge --no-ff --no-commit main >"$TMPROOT/merge-out" 2>&1
}

fresh; git branch -m main; git branch topic
put 'docs/art notes/old-2026-10-24.md' '# Old design\n'
put 'docs/art notes/guide.md' 'See [plan](superpowers/plans/old.md).\n'; commit main
merge_main; run
check staged_merge_inherited_dated_doc_and_reference_pass 0 "$rc"

fresh; git branch -m main; git branch topic
put main.txt 'Main work.\n'; commit main; merge_main
put 'docs/art notes/new-2026-10-25.md' '# New design\n'; git add -A; run
said 'check-scratch: docs/art notes/new-2026-10-25.md: new doc named by date'
check staged_merge_new_dated_doc_fails 1 "$rc"

fresh; git branch -m main; git branch topic
put 'docs/art notes/guide.md' 'See [plan](superpowers/plans/old.md).\n'; commit main; merge_main
printf 'See [plan](superpowers/plans/new.md).\n' >> 'docs/art notes/guide.md'; git add -A; run
said 'check-scratch: docs/art notes/guide.md: line 2 names a scratch file, superpowers/plans/new.md'
check staged_merge_new_reference_fails 1 "$rc"

# Line identity matters, even if the resolution moves or duplicates a parent's line.
fresh; git branch -m main; git branch topic
put 'docs/art notes/guide.md' 'See [plan](superpowers/plans/old.md).\n'; commit main; merge_main
put 'docs/art notes/guide.md' 'New introduction.\nSee [plan](superpowers/plans/old.md).\nSee [plan](superpowers/plans/old.md).\n'
git add -A; run
check staged_merge_repositioned_parent_reference_passes 0 "$rc"

# An inherited line in a different file does not excuse a new reference at this path.
fresh; git branch -m main; git branch topic
put docs/old.md 'See [plan](superpowers/plans/old.md).\n'; commit main; merge_main
put 'docs/art notes/new.md' 'See [plan](superpowers/plans/old.md).\n'; git add -A; run
said 'check-scratch: docs/art notes/new.md: line 1 names a scratch file'
check staged_merge_reference_copied_to_new_path_fails 1 "$rc"

# HEAD's version also counts when a resolution duplicates a line the topic deleted.
fresh; put docs/guide.md 'See [plan](superpowers/plans/old.md).\nAnchor.\n'; commit old
git branch -m main; git checkout -qb topic
put docs/guide.md 'Topic replacement.\n'; commit topic
git checkout -q main; put main.txt 'Main work.\n'; commit main
git merge --no-ff --no-commit topic >"$TMPROOT/merge-out" 2>&1
put docs/guide.md 'See [plan](superpowers/plans/old.md).\nAnchor.\nSee [plan](superpowers/plans/old.md).\n'; git add -A; run
check staged_merge_reference_from_head_passes 0 "$rc"

fresh; git branch -m main; git branch topic
put 'docs/art notes/old-2026-10-24.md' '# Old design\n'
put 'docs/art notes/guide.md' 'See [plan](superpowers/plans/old.md).\n'; commit main
git worktree add -q "$TMPROOT/merge linked$case_no" topic; cd "$TMPROOT/merge linked$case_no"
put topic.txt 'Topic work.\n'; commit topic
git merge --no-ff --no-commit main >"$TMPROOT/merge-out" 2>&1
GIT_DIR=$(git rev-parse --absolute-git-dir); export GIT_DIR
run
unset GIT_DIR
check staged_linked_worktree_merge_inherited_content_passes 0 "$rc"

fresh; git branch -m main; git branch topic; git branch extra
put docs/main.md 'See [plan](superpowers/plans/main.md).\n'; commit main
git checkout -q extra
put 'docs/art notes/extra-2026-10-24.md' '# Extra design\n'
put 'docs/art notes/extra.md' 'See [plan](superpowers/plans/extra.md).\n'; commit extra
git checkout -q topic; put topic.txt 'Topic work.\n'; commit topic
git merge --no-ff --no-commit main extra >"$TMPROOT/merge-out" 2>&1
run
check staged_octopus_merge_inherited_content_passes 0 "$rc"

fresh; git branch -m main; git branch topic
put docs/programs/x.md '# Program\n'; commit program; merge_main; run
said 'program state lives outside this repository, read docs/programs/README.md'
check staged_merge_parent_program_fails 1 "$rc"

fresh; put docs/programs/x.md '# Program\n'; commit program
git branch -m main; git checkout -qb topic
put topic.txt 'Topic work.\n'; commit topic
git checkout -q main; put main.txt 'Main work.\n'; commit main
git merge --no-ff --no-commit topic >"$TMPROOT/merge-out" 2>&1
run
said 'program state lives outside this repository, read docs/programs/README.md'
check staged_merge_head_program_fails 1 "$rc"

fresh; git branch -m main; git branch topic; git branch extra
put main.txt 'Main work.\n'; commit main
git checkout -q extra; put docs/programs/state.json '{"status":"Active"}\n'; commit extra
git checkout -q topic; put topic.txt 'Topic work.\n'; commit topic
git merge --no-ff --no-commit main extra >"$TMPROOT/merge-out" 2>&1
run
said 'program state lives outside this repository, read docs/programs/README.md'
check staged_octopus_merge_parent_program_fails 1 "$rc"

echo "== self exclusion =="
fresh; mkdir -p Scripts/tests; cp "$SCRIPT" Scripts/check-scratch.sh; cp "$here/check-scratch.test.sh" Scripts/tests/check-scratch.test.sh
commit scripts; run_in_repo() { set +e; sh Scripts/check-scratch.sh "$@" >"$OUTFILE" 2>&1; rc=$?; set -e; }; run_in_repo --tree
check tree_self_exclusion_follows_script_location 0 "$rc"

# Inside a git hook git exports GIT_DIR, which must not stop the check from finding its own folder.
# The staged line names a scratch path, so it only passes while the test file stays excluded.
fresh; mkdir -p scripts/tests; cp "$SCRIPT" scripts/check-scratch.sh; cp "$here/check-scratch.test.sh" scripts/tests/check-scratch.test.sh
commit scripts; printf '# see docs/superpowers/plans/x.md\n' >> scripts/tests/check-scratch.test.sh; git add scripts/tests/check-scratch.test.sh
GIT_DIR=$(git rev-parse --absolute-git-dir); export GIT_DIR
set +e; sh scripts/check-scratch.sh >"$OUTFILE" 2>&1; rc=$?; set -e
unset GIT_DIR
check staged_hook_git_dir_set_passes 0 "$rc"

fresh; mkdir -p scripts/tests; cp "$SCRIPT" scripts/check-scratch.sh; cp "$here/check-scratch.test.sh" scripts/tests/check-scratch.test.sh
commit scripts; git worktree add -q "$TMPROOT/linked$case_no" -b linked; cd "$TMPROOT/linked$case_no"
printf '# see docs/superpowers/plans/x.md\n' >> scripts/tests/check-scratch.test.sh; git add scripts/tests/check-scratch.test.sh
GIT_DIR=$(git rev-parse --absolute-git-dir); export GIT_DIR
set +e; sh scripts/check-scratch.sh >"$OUTFILE" 2>&1; rc=$?; set -e
unset GIT_DIR
check staged_linked_worktree_git_dir_set_passes 0 "$rc"

echo "== usage =="
fresh; run --nonsense
check unknown_mode_exits_2 2 "$rc"

echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
