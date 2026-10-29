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
3. **branch:** `--branch` if given; otherwise the current branch, left out
   when it is `master` or `main` (today's rule). Recommendation: keep today's
   rule; see decision 3.
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
     after the directory. [#2](https://github.com/pflagerd/git-stuff/issues/2)'s
     example (`blog/ git@github.com:pflagerd/blog-bootstrap bok-blog`) becomes
     an acceptance test: it must create `blog/` on branch `bok-blog`.
   - **Exists but fails the `checkDisk()` test:** warning, skipped.
   - **Exists and is a nested repo:** `git -C <dir> pull --ff-only`.
3. A git failure for one repo doesn't stop the others; exit 1 at the end.

Two behaviour changes from today, both recommendations:

- **`--ff-only`.** Plain `git pull` may create a merge commit in a nested
  repo she isn't looking at. `--ff-only` refuses instead, and she merges by
  hand ([git-pull `--ff-only`](https://git-scm.com/docs/git-pull#Documentation/git-pull.txt---ff-only)).
- **No branch switching in existing repos.** Today it runs `git checkout`
  before pulling. Switching branches in a repo she may be working in is
  surprising; instead, if the current branch differs from the listed one,
  warn and pull the current branch. Switching happens only right after a
  clone.

## Implementation shape

- New files `checkNested.d`, `addNested.d`, `removeNested.d`, `pullNested.d`,
  each a short `main()`; shared option parsing and output in one helper
  module. `add_nested.d` and `pull_nested.d` are replaced (the program names
  in `bin/` stay the same).
- All git commands run with argument lists, never a shell
  ([#3](https://github.com/pflagerd/git-stuff/issues/3)).
- Tests: the logic is already unit-tested in the classes; end-to-end tests
  run the built programs against local repositories in a temp directory
  (no network or SSH key), written with pytest, which `setup.sh` installs
  and `test_add_nested.py` already uses.
- Closes, once merged: #2, #3, #5, #8, #9, #10.

## Decisions

1. **Commands:** the four above, including the new `check-nested` and
   `remove-nested`? (Recommended: yes.)
2. **Exit statuses** 0 / 1 / 2 as above? (Recommended: yes.)
3. **Recorded branch in `add-nested`:** (a) today's rule, leave out
   `master`/`main` (recommended); (b) leave out the remote's default branch,
   whatever its name (needs `origin/HEAD`, which isn't always set); (c) always
   record it; (d) only with `--branch`.
4. **Several arguments:** all or nothing (recommended), or each on its own?
5. **Drop the url form of `add-nested`?** (Recommended: yes.)
6. **`pull-nested`:** `--ff-only` (recommended), and no branch switching in
   existing repos (recommended)?
7. **End-to-end tests in pytest** (recommended), or another way?
