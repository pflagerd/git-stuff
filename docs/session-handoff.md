# Session handoff

Written 2026-11-22. This describes one moment in time; check `git log` for
anything newer before relying on it.

It lets a new Claude Code session, on the owner's Kubuntu machine or in the
cloud, carry on without the old conversation. It does not repeat the rules in
`CLAUDE.md` or the designs in the other files in `docs/`; it points to them.

## Summary

- The five D commands (`add-nested`, `pull-nested`, `push-nested`,
  `check-nested`, `remove-nested`) are written, tested and on `master`.
- Issue #20 (result structs instead of status strings) is finished and closed.
- The owner's commit `e501a81` deleted the Python scripts, most bash helpers
  and the prebuilt binaries. `README.md`, `CLAUDE.md`, `TODO` and two design
  docs still describe them; fixing that is waiting on the owner's decision.
- Next: the owner chooses among the steps under "Proposed next steps".

## State of the code

- Everything is on `master`, committed and pushed. The last two commits are
  `7c416fd` (2026-11-12: `entryFor` returns an `EntryResult`, the last step
  of #20) and the owner's own `e501a81` "progress" (2026-11-18).
- `e501a81` deleted 19 files: every top-level Python script, the bash
  helpers `bin/add`, `bin/commit`, `bin/commit-and-push`,
  `bin/add-commit-push`, `bin/push`, `bin/pull`, `bin/fetch`, `bin/remotes`
  and `bin/rev`, and the prebuilt binaries `bin/add-repo-to-desktop`,
  `bin/pull-desktop-repos` and `bin/template`. See
  `git show --stat e501a81`.
- What is left outside the D code: `gdb/d_arrays.py` (stays Python on purpose,
  see `CLAUDE.md`), `bin/ls-repos` (a bash script), `setup.sh`, and two notes
  nobody has looked into yet:
  - `add_nested.d.todo`: a rule about the default branch and a grid of test
    cases (directory or url argument, directory present or not, has `.git` or
    not, has `origin` or not, default branch name).
  - `pull_nested.d.todo`: one line, "I need tests for pull_nested."
  Both date from September 2026, before the D rewrite; some of their cases
  may already be covered by the unit tests. That is a guess until someone
  compares them.
- `make test` passes: "11 modules passed unittests", then the five
  `--help` and unknown-option checks. Checked in the cloud container (git
  2.43.0, LDC 1.36.0) on 2026-11-22, and earlier on the owner's machine (git
  2.53.0).
- A weakness left on purpose: `EntryResult.gitReposEntry` can be read even
  when the outcome is not `found`. `std.sumtype` could make that impossible;
  it was not tried.

## What is out of date, and where

Checked on 2026-11-22 by reading, not only by searching (short names such as `add` and
`pull` give false matches). Line numbers are as of `e501a81`.

`README.md`:
- Lines 119 to 122: `python3` is installed "for the remaining Python
  scripts". No such scripts remain.
- Line 234: `push-nested` pushes to every remote "as `bin/push` does";
  `bin/push` is gone.
- Lines 293 to 314, the whole "Bash helpers in `bin/`" section: the table
  lists nine deleted helpers (only `ls-repos` remains), and lines 312 to 314
  describe the three deleted binaries.
- Lines 316 to 350, the whole "Python scripts" section.
- Lines 392 to 393: issue #1, about `add-commit-push` and `commit-and-push`.
- Lines 397 to 404: "Replace the Python scripts with D, or delete them".
- Lines 408 to 417, the whole "Known issues" section, about a deleted script.
  Line 406 links to it.
- Line 291 ("the one Python file meant to stay") is still true.

`CLAUDE.md`, "Project facts":
- Lines 89 to 90: "Bash helpers in `bin/`, alongside some committed prebuilt
  binaries (e.g. `bin/pull-desktop-repos`, `bin/template`)".
- Lines 91 to 93: "Python scripts at the top level. These are being replaced
  by D or deleted". The exception for `gdb/d_arrays.py` (lines 93 to 95)
  still holds.

`TODO`:
- Lines 6 to 8: lists "the Python issues #14-#18 and #11" as remaining work.
- Lines 26 to 27: the same, as a plan. Lines 28 to 29 (about
  `gdb/d_arrays.py`) still hold.
- Lines 21 to 22 mention `add_nested.d`, `test_add_nested.py` and
  `pull_nested.d` as deleted. That is correct (they went long before
  `e501a81`); the `.todo` files are different files.

`docs/push-nested-proposal.md`: lines 12 to 14 ("What exists today":
`bin/push` and `add_origin_host_remote.py`), and lines 46, 48 and 67, which
compare options with `bin/push`. This is a record of a decision, so it may
be right to leave it and add a note that those files are gone.

`docs/nested-commands-proposal.md`: lines 10 and 16 describe `add_nested.d`
and `pull_nested.d`, deleted before `e501a81`; lines 245 to 248 mention
pytest and Python. Also a record of decisions.

Not about deleted files, but also stale: the "Status" line 3 of
`docs/nested-repos-design.md` ("not yet implemented", branch
`gitignore-serialization`) and of `docs/nested-commands-proposal.md` ("not
implemented yet"). Both are implemented and on `master`.

`setup.sh` line 13 still installs `python3`; that is issue #18.

## Issues

On GitHub, repository `pflagerd/git-stuff` (public). As of 2026-11-22,
according to the old session; check GitHub for the current state.

- #20, no status strings, result structs: closed as completed. Decision in
  `docs/result-types.md`.
- Open, and probably overtaken by `e501a81`: #1, #11, #14, #15, #16, #17.
  They are about the deleted helpers and scripts.
- #18, remove `python3` from `setup.sh`: can probably be done now. Before
  doing it, check whether anything else needs `python3`. GDB runs
  `gdb/d_arrays.py` with its own embedded Python, so I believe that does not
  need the `python3` package, but that should be confirmed on her machine.
- Open and still valid:
  - #21: use `Nullable` instead of `""` for "no value" string returns.
    Examples: `currentBranch`, `remoteDefaultBranch`, `originUrl`,
    `readIfExists`, the optional `toPath` of the two `write()` methods, and a
    lookup in `unescapeField` (see "What is left" in
    `docs/result-types.md`).
  - #7: check that directories named by `.gitignore` lines outside the
    managed block still exist.
  - #4: a utility to create remote repositories on the owner's servers.

## Proposed next steps

Proposed to the owner; she has not chosen yet. Ask her.

1. Update `README.md` and `CLAUDE.md` to match the deletions (and `TODO`,
   and perhaps a note in the two proposals). How to do it is her decision.
2. Close the overtaken issues, each with a one-line comment pointing to
   `e501a81`. Only if she asks (see below).
3. Look at #18.
4. Or go straight to #21.

## Standing instructions not in CLAUDE.md

- **Log the conversation on issue #21.** Each interaction (one message from
  the owner plus the reply) becomes one comment on #21, posted at the end of
  the reply. Layout:
  - first line: `**Interaction** · <date time> UTC`
  - `**User:**`, then her message verbatim in a fenced `text` code block
  - `**Claude:**`, then the text of the reply
  - footer: a `---` line, then `_Generated by [Claude Code](https://claude.ai/code)_`

  Wrap any `@name` outside code in backticks, so GitHub notifies nobody.
  Never include her email address, tokens or session links: the repository is
  public. Issue #20 holds interactions 1 to 142 of the old session. If #21 is
  closed, ask her where the log goes next.
- Don't close or comment on issues (other than the log) unless she asks.
- Her preferences:
  - links to authoritative primary sources for claims;
  - "I guess" or "I believe" when a claim is backed neither by a source nor
    by something actually run;
  - an explanation of each argument of any command shown to her;
  - she uses bash and vi on Kubuntu 26.04 on an AMD machine, prefers
    open-source tools, and uses ssh for git exclusively.

## Working habits that proved their worth

- **Small steps, each with `make test`.** A failure then points at one small
  change, and every commit on `master` builds and passes.
- **Sabotage checks.** Before trusting a new test, break a scratch copy of
  the code on purpose and confirm the test fails. A test that cannot fail
  proves nothing.
- **Read the `--word-diff` for renames** (`git diff --word-diff`). Tests
  cannot tell a wrong name from a right one, and a word diff shows each
  renamed word on its own.
- **Take test expectations from real git** where possible (run git and
  record what it does), rather than from memory of what git should do.
  `gitCloneDirectoryName.d`'s tests were rebuilt this way.

## Environment notes

- The cloud container could not delete remote branches (the proxy answered
  403).
- From the cloud container, `dlang.org` and `git-scm.com` did not resolve, so
  some claims about the D spec and git's documentation in the old session
  were made from memory, not checked against the page. Where it matters,
  check them again.
- On the owner's machine these limits may not apply.

## Moving the old session to the owner's machine

From the Claude Code docs as looked up on 2026-11-22; none of it was tried.

- The old session ran in the cloud. The docs describe pulling a cloud
  session down only from the `claude` command in a terminal, not from the
  desktop app: in a clean clone of this repository, `claude --teleport`
  shows a list of cloud sessions to choose from
  ([Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)).
- Parts of the old conversation that were compacted arrive as summaries
  only, which is why this note exists.
- To carry on in the desktop app afterwards: close the session in the
  terminal, then type `/resume` in the desktop app's prompt box
  ([Desktop: coming from the CLI](https://code.claude.com/docs/en/desktop#coming-from-the-cli)).
  The `/desktop` command, which does this in one step, is not available on
  Linux.
- A new session that starts from this note instead needs none of that.

## Where the history lives

- Issue #20: interactions 1 to 142 of the old session, and the discussion of
  result structs.
- Issue #21: the conversation log from here on.
- `docs/`: the designs and decisions (`nested-repos-design.md`,
  `nested-commands-proposal.md`, `push-nested-proposal.md`,
  `result-types.md`) and this note.
- `git log`: every step, one change per commit.
