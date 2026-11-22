# check-nested: report nested repos that `.gitrepos` doesn't list (proposal)

Status: **proposal; decisions below are not made yet.** Issue:
[#15](https://github.com/pflagerd/git-stuff/issues/15). Builds on
`docs/nested-repos-design.md` (`ParentDirectory.checkDisk()`) and follows the
conventions of `docs/nested-commands-proposal.md`.

## The problem

`ParentDirectory.checkDisk()` works in one direction only. For each entry in
`.gitrepos`, it checks that the directory exists and is a git repository
with that url. It never lists the parent directory's contents. So a git
repository in the parent directory that `.gitrepos` doesn't list produces no
warning, and a `git init` in the parent would then try to track its files.

The deleted `find_desktop_directories_not_in_%2Egitrepos.py` covered this
case (`e501a81` removed it); nothing in D replaced it.

On 2026-11-22, `~/desktops/default` had 62 entries in `.gitrepos` and eight
direct subdirectories that were git repositories of their own but not
listed. `check-nested` reported none of the eight.

## What stays the same

- **A new numbered item in `checkDisk()`.** It becomes item 6, so only
  `check-nested` reports it (no other command calls `checkDisk()`).
- **Same test for "is a repo".** "Is a git repository of its own" is
  `ParentDirectory.checkRepository()`, the test the other items use, so the
  question keeps one answer.
- **One `Finding` per directory.** `directory` is `"/name/"`, and the message
  names the parent and says how to register it, for example:
  `<parent>: /chromium/ is a git repository but is not listed in .gitrepos (add it with add-nested)`.
- **Exit status as today.** It is 1 while any finding remains.
- **One `git rev-parse` per subdirectory checked.** That is about 70 on the
  directory above, which is fast enough. I believe this, but have not
  measured it.

## Decisions

### 1. How deep to look

- **(a) Direct subdirectories of the parent only. (Recommended.)** This
  matches the deleted script, the README's picture of a parent ("a Desktop
  folder of clones"), and the data above. It is cheap and easy to test.
  It misses `tools/gamma/` when only `tools/beta/` is listed.
- (b) Recursively. Stop at each repository found, since a repository's
  contents belong to it, and skip directories the parent's `.gitignore`
  ignores. This catches deeper repos, but it can walk large trees of plain
  directories, and the ignore test would mean reimplementing git's
  `.gitignore` matching or running `git check-ignore`, which needs the
  parent to be a git repository.
- (c) (a), plus one level inside each directory that holds a deeper
  `.gitrepos` entry (`tools/` for `/tools/beta/`). A middle way, with an
  extra rule to explain.

### 2. Repos she leaves out on purpose

A repository may sit in the parent on purpose without being nested-managed,
for example a private one. She needs a way to stop the warning.

- **(a) Skip a directory that a `.gitignore` line outside the managed block
  names. (Recommended.)** Writing `/household/` by hand already says "I know
  it's here; don't track it", so no new file or syntax is needed. The match
  uses the same normalisation as `looseDirectory()`.
- (b) Always report. The only way to silence the warning is to register the
  repository or move it.
- (c) A separate list of exceptions (a new file, or a marker in
  `.gitrepos`). This is the most explicit, but it adds a file format, and
  `.gitrepos` comments are not preserved when it is written.

Today's data shows the interaction. `/household/` is in `.gitignore` but not
`.gitrepos`, so (a) skips it, while the other seven are still reported.

### 3. Fixable with `--fix`?

- **(a) No. (Recommended.)** This matches #15's suggestion and
  `checkDisk()`'s rule that its findings need her judgement. Registering a
  repository means choosing its url and branch, which `add-nested` does.
- (b) Yes: `--fix` registers each one, as `add-nested <dir>` would, reading
  `origin`. This is convenient, but `--fix` would then add entries she might
  not want, and a repository with no `origin` would need a different
  outcome.

### 4. What counts as a candidate

Recommended:
- Skip symbolic links. A parent repository tracks a symlink as a link, not
  as the repository it points to.
- Skip `.git`.
- Include other names starting with `.`: one could be a repository.
- Include only directories, in name order, so the output is stable.

## Tests

The tests go in `parentDirectory.d`'s `checkDisk()` unittests, using a
scratch parent with:
- a listed repo;
- an unlisted repo;
- an unlisted repo named by a hand-written `.gitignore` line (decision 2);
- a plain directory;
- a file;
- a symlink to a repo;
- for 1(b) or 1(c), a deeper repo.

As `CLAUDE.md` requires, these tests must not depend on git defaults. They
need only `git init`, and they assert on `Finding.directory` and the message.

Before writing the check, run the existing `checkDisk()` and `check-nested`
tests against it. Any scratch parent that holds a repository it doesn't list
will start reporting a new finding, and that change has to be deliberate.

Afterwards:
- update the README's `check-nested` section;
- run a sabotage check: break the new check in a scratch copy and confirm
  that a test fails.

## Answers

(To be filled in when the decisions are made.)
