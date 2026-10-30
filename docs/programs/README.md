<!--
Canonical copy: game-template/docs/programs/README.md. Copied verbatim into every repo that carries
scripts/check-scratch.sh. Do not hand-edit a copy. Change it in game-template and re-propagate.
-->
# Programs

Program state lives in the owner's program store, outside this repository. A program spans more than
one landing. Read it on demand with gauge:program_get using its program id, or find it with
gauge:program_list filtered by this repository. Create and change it with gauge:program_create and
gauge:program_update. Do not create a repo tracker or design file. Remaining design lives in the
program's final Design section.

A resumed chat whose draft names docs/programs/<name>.md must read gauge:program_get with id <name>
before continuing. A branch-only or newer branch tracker stays on that branch as recovery material.
The merge check refuses it. Apply its still-current changes through the program tools against the
current revision and remove the repo file from the proposed merge. Do not replace newer store state
from an old branch.

At a milestone's start set Active. After it lands update Done with evidence. Record owner
gates/questions when they arise. A chat plan describes work inside the milestone and links the
program id, never restating milestones. At completion move decisions still in force into living docs
and close with gauge:program_close. Hosted runners and other machines do not read the store. A chat
there hands program changes to a Mac chat.

Only README.md may be committed under docs/programs/. The check enforces this in the resulting index
and CI, including inherited merge files. Scratch-reference and dated-doc rules keep their existing
parent comparisons.

## Living docs and work files

**Living docs** are the current truth about the system. They are named by topic, never by date, and
describe the system as it is. Superseded text is rewritten or deleted, because git history is the
archive. A reason or gotcha sits next to the behaviour it explains and stands alone, with no link into
scratch. A behaviour change and its doc update land in the same commit.

**Work files** are specs, plans, subagent ledgers, briefs, reports, receipts and brainstorm output.
They live outside the repository in the work folder `~/.local/share/agent-work/<repo>/<key>/`, where
`<key>` is the program id or the branch topic, so a reboot, a worktree removal or
`git clean` cannot take them. They stay while the work or program runs and are removed when it ends.
They are never committed, and no tracked file names a file inside them. `docs/superpowers/` and
`.superpowers/` stay ignored scratch roots, and a worktree's `.superpowers/sdd` is a link into the work
folder so the subagent ledger is durable. A bare mention of these folders in a rule is fine. A plan for a
program milestone is named `<program>-m<N>-<topic>` so a new chat finds it by name. Output that can be
regenerated, such as captures, frames, contact sheets, CI downloads and logs, goes in
`/tmp/<repo>-<key>/` with mode 0700, never in the work folder.

The staged check treats merge parents as existing content for scratch references and dated docs.
A dated doc is new only when none of the parents has that path. A scratch reference is new only when
its exact line is absent from that file in every parent. This includes the first parent and all heads
of an octopus merge. Whole-tree checks still inspect all tracked content.
