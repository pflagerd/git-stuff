# Nested repos: command-line tools (proposal)

Status: **proposal, awaiting decisions.** Branch: `gitignore-serialization`.
Builds on `docs/nested-repos-design.md` (`GitIgnore`, `GitRepos`,
`ParentDirectory`). Recommendations are marked; numbered **decisions** at the
end are hers to make before any code is written.

## What exists today

- `bin/add-nested <directory | url> ...` (`add_nested.d`): registers an
  existing clone in `.gitignore` and `.gitrepos`, reading the url from
  `origin` and the branch from `git branch` (left out for `master`/`main`).
  Broken: relative paths fail ([#8](https://github.com/pflagerd/git-stuff/issues/8)),
  only the first argument is handled ([#9](https://github.com/pflagerd/git-stuff/issues/9)),
  updated entries aren't saved ([#10](https://github.com/pflagerd/git-stuff/issues/10)).
- `bin/pull-nested` (`pull_nested.d`): for each `.gitrepos` line, clones the
  directory if missing, otherwise checks out the listed (or directory-named)
  branch and runs `git pull`. Works in simple cases (tested earlier in this
  work); [#2](https://github.com/pflagerd/git-stuff/issues/2) reports a case
  where it cloned to the wrong directory and branch.
- Both build git commands as shell strings, which breaks on names with
  spaces ([#3](https://github.com/pflagerd/git-stuff/issues/3)).

## Proposed commands

Four small programs, each a thin layer over `ParentDirectory`:

| Command | Does | Touches the network? |
|---|---|---|
| `check-nested` | Reports `check()` and `checkDisk()` findings; with `--fix`, repairs the fixable ones and writes the files | No |
| `add-nested <directory>...` | Registers existing clones | No |
| `remove-nested <directory>...` | Unregisters; **never deletes a directory** | No |
| `pull-nested` | Clones missing repos, pulls existing ones | Yes (git over SSH) |

**Recommendation:** a separate `check-nested` rather than a `--check` mode on
the others, so checking never risks network access or changes.

### Options shared by all four

| Option | Meaning |
|---|---|
| `-C <directory>` | Work in that parent directory instead of the current one (like `git -C`) |
| `--fix` | Before doing its job, apply `ParentDirectory.fix()` and write the files |
| `-h`, `--help` | Usage |

Parsed with Phobos [`std.getopt`](https://dlang.org/phobos/std_getopt.html).

### Output and exit status

- Findings go to standard error, one per line, as the message already reads
  (`<path>: <problem>`), prefixed `warning:` (fixable ones also say
  `(fixable with --fix)`).
- Git's own output is passed through, under a header line naming the repo
  (`== /alpha/`), so she can tell which repo said what.
- **Exit status** (the same three-way convention as GNU grep:
  [grep exit status](https://www.gnu.org/software/grep/manual/html_node/Exit-Status.html)):

| Status | Meaning |
|---|---|
| 0 | Did its job, and no findings remain |
| 1 | Did what it could, but findings remain or a git command failed for some repo |
| 2 | Couldn't start: bad usage, or `.gitignore`/`.gitrepos` couldn't be parsed |

### `check-nested [-C dir] [--fix]`

1. Load `ParentDirectory` (a parse error: message, exit 2).
2. With `--fix`: `fix()`, then `write()`.
3. Print `check()` and `checkDisk()` findings; exit 0 if none, else 1.

### `add-nested [-C dir] [--fix] [--branch <name>] [--url <url>] <directory>...`

For each directory:

1. It must pass the same test as `checkDisk()`: exists, and
   `rev-parse --show-toplevel` names it. Otherwise it's an error for that
   argument.
2. **url:** the stored `remote.origin.url` (the same value `checkDisk()`
   compares). `--url` overrides it; with no `origin` and no `--url`, it's an
   error for that argument.
3. **branch** (decision 3, option a′): `--branch` if given; otherwise the
   current branch (`git symbolic-ref --short HEAD`). No current branch
   (detached HEAD) is an error for that argument unless `--branch` is given.
   The branch is **left out** of `.gitrepos` only when `pull-nested` would
   arrive at the same branch by itself, so the two tools can't disagree:
   - If the directory's last component differs from the name `git clone`
     would choose for the url (`gitCloneDirectoryName.d`), a fresh clone
     would check out a branch named after the directory if the remote has
     one, and otherwise stay on the default. Leave the branch out only if
     the current branch has the directory's name and
     `refs/remotes/origin/<that name>` exists locally. When she is on the
     default branch, record it: if the remote later gained a branch named
     after the directory, a line without a branch would quietly change
     meaning.
   - Otherwise `pull-nested` would get the remote's default branch: leave it
     out only if the current branch equals it, read locally from
     `refs/remotes/origin/HEAD` (`git symbolic-ref --short
     refs/remotes/origin/HEAD`, e.g. `origin/main`;
     [git-symbolic-ref](https://git-scm.com/docs/git-symbolic-ref)).
   - Anything unknown records the branch: no `origin/HEAD`, a `--url` that
     isn't `origin`'s url, or any error. Recording is always correct;
     leaving it out is only a shorthand.

   The rule "which branch does a line with no branch mean" is one shared
   function used by both `add-nested` and `pull-nested`. If decision 6 drops
   the directory-name rule, the first bullet goes away.
4. `ParentDirectory.add(entry)`.

Then `write()` once, then report remaining `check()` findings.

- **Several arguments ([#9](https://github.com/pflagerd/git-stuff/issues/9)).**
  Recommendation: **all or nothing**. Every argument is validated first; if
  any fails, nothing is written and the exit status is 1. Partial writes
  would leave her guessing which arguments took effect.
- **`--branch`/`--url` with several directories:** refused (exit 2); they
  only make sense for one.
- **A url argument** (today's `add-nested <url>`): recommendation, **drop
  it**; the directory form covers it. Cloning-and-adding could be a later
  `add-nested --clone`.

### `remove-nested [-C dir] [--fix] <directory>...`

`ParentDirectory.remove()` for each; a directory in neither file is a
warning. `write()` once. The directory itself is never touched; the message
says so, so she isn't left wondering.

### `pull-nested [-C dir] [--fix]`

1. Load; with `--fix`, `fix()` and `write()`; print `check()` findings as
   warnings (they don't stop the pull).
2. For each `.gitrepos` entry, in order, under a `== /dir/` header:
   - **Missing:** `git clone <url> <dir>`, then check out the branch: the
     listed one, or else, if the directory's name differs from the name
     `git clone` would choose (`gitCloneDirectoryName.d`), a branch named
     after the directory **if the remote has one**
     (`git rev-parse --verify --quiet refs/remotes/origin/<name>`, which a
     fresh clone answers without another network call). If it doesn't, the
     clone stays on the remote's default branch, with a note saying so
     (decision 6 part 3). [#2](https://github.com/pflagerd/git-stuff/issues/2)'s
     example (`blog/ git@github.com:pflagerd/blog-bootstrap bok-blog`) becomes
     an acceptance test: it must create `blog/` on branch `bok-blog`.
   - **Exists but fails the `checkDisk()` test:** warning, skipped.
   - **Exists and is a nested repo:** `git -C <dir> pull --ff-only`
     (decision 6 part 1). If the branch can't be fast-forwarded, git's
     message is shown and the repo is left untouched.
3. A git failure for one repo doesn't stop the others; exit 1 at the end.

Two behaviour changes from today, both recommendations:

- **`--ff-only`** (decided, 6 part 1). What plain `git pull` does when her branch
  and the remote's have diverged depends on her own `pull.*` settings
  ([git-pull](https://git-scm.com/docs/git-pull)). Observed with git 2.43:
  with none set it refuses (`Need to specify how to reconcile divergent
  branches`); with `pull.rebase=false` it merges, and a conflict leaves the
  nested repo in the middle of a merge she isn't looking at; with
  `pull.rebase=true` it rewrites her local commits. `--ff-only` behaves the
  same whatever her settings: it only moves a branch forward and otherwise
  refuses, leaving the repo untouched
  ([`--ff-only`](https://git-scm.com/docs/git-pull#Documentation/git-pull.txt---ff-only)).
  (An earlier version of this proposal said plain `git pull` "may create a
  merge commit"; that is only true with her settings saying to merge.)
- **No branch switching in existing repos** (decided, 6 part 2, option i).
  Today it runs `git checkout` before every pull, without checking whether it
  worked. Observed: a non-clashing uncommitted edit is carried onto the other
  branch; a clashing one makes the checkout fail, and the pull then runs on
  whatever branch she was on. Instead: if the current branch differs from the
  listed (or derived) one, warn and pull the current branch. Switching
  happens only right after a fresh clone. A listed branch therefore means
  "clone it on this branch", not "keep it on this branch".

## Implementation shape

- New files `checkNested.d`, `addNested.d`, `removeNested.d`, `pullNested.d`.
  Each holds `int run(string[] args, File output, File errors)`, which does
  all the work, and a one-line `main()` that calls it, inside
  `version (unittest) {} else { ... }` so test builds can include every
  command module without their `main()`s clashing
  ([D spec: version](https://dlang.org/spec/version.html#predefined-versions)).
  Shared option parsing and output live in one helper module. `add_nested.d` and `pull_nested.d` are replaced (the program names
  in `bin/` stay the same).
- All git commands run with argument lists, never a shell
  ([#3](https://github.com/pflagerd/git-stuff/issues/3)).
- Tests, all in D (decision 7): the classes are already unit-tested. Each
  command is tested in-process by calling its `run()` from `unittest`
  blocks, with output captured through temp files, against real git and
  local repositories in a temp directory (no network or SSH key). One quick
  check per built program covers `main()` and the argument plumbing:
  `--help` exits 0 and an unknown option exits 2.
- Closes, once merged: #2, #3, #5, #8, #9, #10.

## Decisions

1. **Commands:** the four above, including the new `check-nested` and
   `remove-nested`? (Recommended: yes.)
**Answer:** yes
2. **Exit statuses** 0 / 1 / 2 as above? (Recommended: yes.)
**Answer:** yes
3. **Recorded branch in `add-nested`:** (a) today's rule, leave out
   `master`/`main` (recommended); (b) leave out the remote's default branch,
   whatever its name (needs `origin/HEAD`, which isn't always set); (c) always
   record it; (d) only with `--branch`.
**Answer:** (a′): leave the branch out only when `pull-nested` would arrive
at the same branch by itself; record it otherwise, including whenever that
can't be determined. Option (a) was withdrawn: combined with `pull-nested`'s
directory-name rule it records nothing for `blog/` cloned from
`blog-bootstrap` on `master`, and a fresh pull then checks out a branch named
`blog`.
4. **Several arguments:** all or nothing (recommended), or each on its own?
**Answer:** all or nothing
5. **Drop the url form of `add-nested`?** (Recommended: yes.)
**Answer:** Let's discuss this more. Don't do it yet.
6. **`pull-nested`:** (1) `--ff-only` (recommended)? (2) existing repos on a
   different branch: (i) never switch, warn and pull the current branch
   (recommended), (ii) switch only if the working tree is clean, (iii) always
   switch but stop if it fails? (3) keep or drop the directory-name rule (no
   branch listed and the directory name differs from the clone name means a
   branch named after the directory)?
**Answer:** Part 1: yes, `--ff-only`. Part 2: (i), never switch in an
existing repo. Part 3: keep the directory-name rule, but if the remote has
no branch named after the directory, stay on the remote's default branch
(with a note) instead of failing. Decision 3's rule is adjusted to match.
7. **End-to-end tests in pytest** (recommended), or another way?
**Answer:** In D, not pytest: each command tested in-process through its
`run()` (option B), plus a quick check per built program. Python in this
repo is to be replaced by D or deleted.
