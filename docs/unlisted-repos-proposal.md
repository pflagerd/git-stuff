# check-nested: report nested repos that `.gitrepos` doesn't list (proposal)

Status: **all decisions made** (see Answers). **Step 1, the default
mode (direct subdirectories, not fixable), is implemented** in
`ParentDirectory.checkDisk()` item 6. Still to do: `-r`/`--recursive`,
`-f`/`--force`, and `--fix` registering unlisted repos. Issue:
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

### 1b. What `-r` / `--recursive` walks into

Decision 1 makes recursion an option. The question is what the walk does
when it meets each kind of entry. Recommended:
- **Stop at every git repository, listed or not.** A repository's contents
  belong to it. Its own nested repos are its own `.gitrepos`'s business, and
  `check-nested -C` on it checks them.
- **Never follow symbolic links,** the same as decision 4. This also rules
  out loops.
- **Don't descend into a directory that a hand-written `.gitignore` line
  names** (the decision 2 opt-out, if 2(a) is chosen). That lets her keep a
  large plain tree out of the walk.
- **Otherwise descend into every plain directory.** Matching git's full
  `.gitignore` rules (wildcards, `**`, negation) is not attempted, so
  `*.o`-style patterns don't stop the walk.

The alternative is to run `git check-ignore` for the full rules. That works
only when the parent directory is itself a git repository, and it costs one
more process per directory.

`-r` and `--recursive` belong to `check-nested` only, passed to
`parseOptions` like `add-nested`'s `--branch`. `checkDisk()` takes a
`recursive` parameter, so `check()` stays free of disk access.

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
- an unlisted repo named by a `.gitignore` line outside the block, and one
  named inside it (decision 2: neither reported);
- a plain directory;
- a file;
- a dot-directory holding a repo (never reported);
- a symlink to a repo, and a symlink loop;
- for `-r`, an unlisted repo inside a plain directory, one inside an
  unlisted repo, and one inside a named directory (reported only with
  `-f`);
- a plain directory with its own `.gitrepos` (it becomes the nearest
  enclosing parent).

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

1. **Answer (2026-11-22):** direct subdirectories by default (1(a)), with
   `-r` / `--recursive` to search deeper (1(b), as an option). How the
   recursive walk behaves is decision 1b.

1b. **Answer (2026-11-22, revised the same day), not the recommendation:**
   - **Finding a git repository doesn't stop the walk.** It goes on into
     every repository unless the next rule skips it.
   - **Skip a directory that any `.gitignore` line names, inside the managed
     block or outside it.** Skipped means not reported and not walked into.
     This applies to the parent's `.gitignore` and to every nested
     `.gitignore` the walk meets. Each line names a directory relative to
     its own `.gitignore`'s folder, using `looseDirectory()`'s rule, so
     wildcard lines don't name directories. Because the managed block
     names every listed repository, `-r` doesn't walk into listed
     repositories.
   - **`-f` / `--force`, with `-r`:** walk into the skipped directories as
     well. A named directory is still not reported itself, but unlisted
     repositories found inside it are. `-f` is wanted even though it sits
     close to `--fix`, which has no short form. `--force` without `-r` has
     no effect, because the default mode doesn't walk.
   - **Follow symbolic links.** (Not part of the answer, but needed: the
     walk remembers each directory's resolved path and doesn't enter one
     twice, so links can't loop.)
   - **Skip every directory whose name starts with `.`.**

   The first version said to skip only directories named by hand-written
   lines (outside the block), and to walk into every repository, listed or
   not. The revision treats every `.gitignore` line the same.

2. **Answer (2026-11-22, revised):** a directory named by any `.gitignore`
   line, in the managed block or not, is not reported (from 1b). So
   `/household/`, named by a hand-written line, is not reported.

3. **Answer (2026-11-22):** 3(b). `--fix` registers unlisted
   repositories, as `add-nested <dir>` would, reusing `entryFor()` in
   `addNested.d`, which reads the url from `origin` and the branch by
   `add-nested`'s rule.
   - **Only `check-nested` does this.** Its `--fix` reads git state from
     disk. `ParentDirectory.fix()` works in memory only, and the other
     commands' `--fix` stay as they are.
   - **Some stay unfixable.** A repository for which `entryFor()` returns
     `noOrigin` or `detachedHead` is still reported, but not marked
     fixable, and the message says to run `add-nested` with `--url` or
     `--branch`.
   - **3b. Answer (2026-11-22):** (i). `-r --fix` registers a repository
     only when its nearest enclosing parent (see "listed" below) is the `-C`
     directory itself. Any other repository is reported, not fixable here,
     with "run `check-nested -C <that directory> --fix`". One run never
     writes into another repository's working tree. That command works even
     where the files don't exist yet, because a missing `.gitignore` or
     `.gitrepos` reads as empty, and `--fix` creates them.
   - Today's case: `pflager.net/projects/genmitsu-jinsoku-Z3-galvo-laser`
     would be reported with "run `check-nested -C
     ~/desktops/default/pflager.net --fix`".

4. **Answer (2026-11-22), not the recommendation:** follow symbolic links
   (as in 1b), and skip all dot-directories, `.git` included.

Rules that follow from these answers:
- **What "listed" means below the top level.** A repository's *nearest
  enclosing parent* is the nearest directory above it that is either a git
  repository or has a `.gitrepos`. The repository counts as listed when
  that parent's `.gitrepos` lists it, with the path relative to that
  parent. Both halves of the rule come from real data on 2026-11-22:
  - `openai-product-explorations/deep-research/` is a plain directory with
    its own `.gitrepos`. Counting only repositories as parents would have
    reported its listed repository wrongly.
  - `pflager.net/projects/genmitsu-jinsoku-Z3-galvo-laser` lies inside
    `pflager.net`'s working tree. Counting only `.gitrepos` directories as
    parents would have made it the top parent's business, not
    `pflager.net`'s.
- **`--fix` doesn't change what `-r` walks.** Since every `.gitignore`
  line counts, moving lines into the managed block changes nothing.

Simulated on `~/desktops/default` on 2026-11-22, with a throwaway program
applying the revised answers:
- **Default (direct children):** 7 unlisted repositories, instantly:
  `chromium`, `claude-stuff`, `countdown-timer`, `markdown-viewer`,
  `markdown-wysiwyg-editor`, `pwa-template` and `terminal`.
- **`-r`:** the same 7. The walk visited 44,713 directories in about 5 s.
- **`-r -f`:** 8, adding `pflager.net/projects/genmitsu-jinsoku-Z3-galvo-laser`
  (nearest enclosing parent `pflager.net`), which is neither listed nor
  ignored there. The walk visited 68,033 directories in about 8 s.

The simulation finds repositories by the presence of `.git`, not by
`checkRepository()`, so the real check may differ in edge cases.
