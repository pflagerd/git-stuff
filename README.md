# git-stuff

We want nested git repositories which are cloned to, checked out from, pulled
from, and pushed to their own remotes when the parent repository is cloned,
checked out, pulled and pushed.

Today the tools register nested repos (`add-nested`), clone the missing ones
and fast-forward the rest (`pull-nested`), push them (`push-nested`), check
that everything agrees (`check-nested`) and unregister them
(`remove-nested`). Switching branches
across nested repos is deliberately not done: `pull-nested` never changes the
branch of a repo that already exists, since you may be working in it.

These utilities are for Linux only.

Git's own answer to this is
[submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules), which pin
each nested repo to a specific commit. This project takes a lighter approach:
the parent ignores each nested repo in `.gitignore` and lists it, with its
remote URL and branch, in a plain-text `.gitrepos` file. The tools read and
write those two files.

## Typical use

```bash
make
bin/add-nested -C ~/Desktop --clone git@github.com:pflagerd/alpha.git
bin/add-nested -C ~/Desktop beta
bin/pull-nested -C ~/Desktop
bin/push-nested -C ~/Desktop
bin/check-nested -C ~/Desktop --fix
```

1. `make` builds the five commands into `bin/`, installing the D compiler
   first if it's missing (see [Setup and building](#setup-and-building)).
2. `add-nested --clone <url>` clones a repo into the parent directory given
   with `-C` (here `~/Desktop`) and registers it.
3. `add-nested beta` registers a clone that's already there, `~/Desktop/beta`.
4. `pull-nested` clones whatever `.gitrepos` lists that's missing (say, on
   another machine) and fast-forwards the rest.
5. `push-nested` pushes each nested repo's current branch to all its
   remotes.
6. `check-nested --fix` repairs what it can in `.gitignore` and `.gitrepos`,
   registers clones in `~/Desktop` that `.gitrepos` doesn't list yet, and
   reports anything else.

Without `-C`, each command works in the current directory.

## Files the tools use

These live in the **parent directory**, the one that holds the nested repos,
not in this repository. The parent directory doesn't have to be a git
repository itself (a Desktop folder of clones works); `.gitignore` is kept up
to date either way, ready for a `git init`.

### `.gitrepos`

One line per nested repository, sorted by directory, with fields separated
by spaces:

```
<directory> <remote-url> [<branch>]
```

- `<directory>` is relative to the parent directory, written with a leading
  and trailing `/` (e.g. `/alpha/`, `/tools/beta/`). Any slash form is
  accepted when reading (`alpha`, `/alpha`, `alpha/`), but a doubled slash is
  an error.
- `<remote-url>` is what `git clone` is given, e.g. `git@github.com:u/a.git`.
- `<branch>` is optional. With it, a fresh clone is checked out on that
  branch. Without it, a fresh clone gets a branch named after the directory
  if the directory's name differs from the name `git clone` would choose and
  the remote has such a branch, and otherwise the remote's default branch.
  `add-nested` leaves the branch out only when that would give the branch
  the clone is on.
- `%`, space, tab and newline in a field are written as `%25`, `%20`, `%09`
  and `%0A` (e.g. `/My%20Repo/`); nothing else is escaped.
- Blank lines and lines starting with `#` are skipped when reading, and not
  written back: the tools own this whole file.

Example:

```
/alpha/ git@github.com:pflagerd/alpha.git
/beta/ git@github.com:pflagerd/beta.git dev
```

### `.gitignore`

Each nested directory is also listed in the parent's `.gitignore`, so the
parent repository doesn't track the nested repo's files. The tools keep those
entries in one managed block and change nothing outside it, except that
`--fix` (on any of the commands) moves a line naming a nested repo (such as
`beta/`) into the block. Your other lines, comments and their order are left
alone:

```
*.o
# BEGIN nested repos (managed by add-nested)
/alpha/
/beta/
# END nested repos
tmp/
```

The marker lines must be exactly as shown. Inside the block, entries are kept
sorted and unique; the block is removed when it becomes empty.

### `.forks`

`.forks` records which other repositories were forked from this one. Its
format is described in the comments at the top of the file.

## Setup and building

### Setup

```bash
make setup
```

This runs `./setup.sh`, which installs whichever of these Ubuntu packages are
missing: `ldc` (the D compiler), `make`, `git` and `python3` (left over
from the Python scripts, which are gone;
[#18](https://github.com/pflagerd/git-stuff/issues/18) removes it). It uses `apt-get`
(via `sudo` unless run as root), and apt asks before installing anything. It
can be run again at any time; it installs only what's missing. On a machine
without `make`, you run `./setup.sh` directly.

You rarely need to run it by hand: `make`, `make all` and `make test` treat
the compiler as a prerequisite, so if it's missing they run `./setup.sh`
first. Targets that don't compile, such as `make clean`, never do. If you
build with another compiler (`make DC=dmd`) that isn't installed, `make`
stops with a message, since `setup.sh` only installs LDC.

It supports only Ubuntu and its derivatives, recognised from `ID` or
`ID_LIKE` in [`/etc/os-release`](https://www.freedesktop.org/software/systemd/man/latest/os-release.html).
On anything else (Fedora, Arch, Debian, ...) it warns, installs nothing, and
exits non-zero.

### Building

```bash
make
```

This builds `bin/add-nested`, `bin/pull-nested`, `bin/push-nested`,
`bin/check-nested` and `bin/remove-nested` with debug output compiled in. Every one is linked with
`debugio.d`, which in these `-debug` builds makes standard output
unbuffered, so output appears line by line when stepping through a program
in Kate's debugger. Unit tests are not compiled into them; `make test` runs
those. `make clean` removes them, and `bin/.gitignore` keeps them out of git.

The compiler is set by the `DC` variable, which defaults to `ldmd2`: the
wrapper of the open-source LLVM-based compiler
[LDC](https://github.com/ldc-developers/ldc) that accepts the flags of `dmd`,
the reference D compiler. To build with `dmd` instead (not packaged by
Ubuntu; available from [dlang.org](https://dlang.org/download.html)):

```bash
make DC=dmd
```

## The commands

### What all five share

| Option | Meaning |
|---|---|
| `-C <directory>` | Work in that parent directory instead of the current one (like `git -C`). |
| `--fix` | First repair what can be repaired in `.gitignore` and `.gitrepos` (sort, de-duplicate, move nested-repo lines into the managed block, add missing block entries), and write both files. |
| `--no-check` | Don't check the two files or report their problems; the command only does its own job. It can't be combined with `--fix`, and `check-nested` refuses it, since checking is all it does: both are bad usage (exit status 2). |
| `-h`, `--help` | Print usage. |

| Exit status | Meaning |
|---|---|
| 0 | Did its job, and no problems remain. |
| 1 | Did what it could, but problems remain or something failed for some repo or argument. With `--no-check`, only the latter. |
| 2 | Couldn't start: bad usage, or `.gitignore`/`.gitrepos` couldn't be read; nothing was changed. |

Problems are printed as `warning:` lines on standard error, marked
`(fixable with --fix)` where that applies. Nested directories are given
relative to the parent directory, in any slash form (`alpha`, `/alpha/`,
`tools/alpha`); `.` and `..` aren't allowed. Besides its own job, each
command reports the problems in the two files, as `check-nested` would:
`pull-nested` and `push-nested` before they start, `add-nested` and
`remove-nested` afterwards, on the files as written. `--no-check` leaves
that report out. Git always runs with an argument list, never through a
shell, so names with spaces are safe.

### `add-nested [--branch <name>] [--url <url>] <nested directory>...`

Registers each nested directory, an existing clone, in `.gitrepos` and in the
managed block of `.gitignore`, printing `added /alpha/ <url> [<branch>]` for
each.

- **Every argument is checked first; if any fails, nothing is written.**
  Each must be the top level of its own git repository and have a url and a
  branch. Every problem is reported, not just the first.
- **url:** the stored `remote.origin.url`, or `--url`.
- **branch:** the current branch, or `--branch` (needed for a detached
  HEAD). The current branch is left out of `.gitrepos` only when
  `pull-nested` would arrive at it by itself from a fresh clone (decision 3
  in `docs/nested-commands-proposal.md`); `--branch` is always recorded.
- `--branch` and `--url` need exactly one nested directory.
- Afterwards it reports the problems left in the two files as written,
  unless you give `--no-check`.

**`add-nested [--branch <name>] --clone <url> [<nested directory>]`** clones
`<url>` first, into the nested directory given or else the one `git clone`
would choose, then registers it as above. Everything that can be checked
without the network is checked first (both files, the directory rules, and
that the directory doesn't exist yet), so a mistake costs no download. The
clone gets the branch `pull-nested` would give it: `--branch`, else a branch
named after the directory if the remote has one, else the default. If the
clone succeeds but the branch can't be checked out, the clone is kept,
unregistered, and the message says how to register it.

### `pull-nested`

For each nested repo in `.gitrepos`, under a `== /alpha/` header, with git's
own messages shown as they happen:

- **Missing:** `git clone <url> <directory>`, then the branch as described
  for `.gitrepos`; when the directory-name rule finds no such branch, it says
  it's staying on the default.
- **Exists but isn't a nested repo:** a warning; skipped.
- **Exists:** `git pull --ff-only`, which only ever moves the branch forward;
  if the branch has diverged it refuses and leaves the repo as it was,
  whatever your `pull.*` settings say. **It never switches branches** in an
  existing repo: if you're on a different branch from the one `.gitrepos`
  means, it warns and pulls the branch you're on.

A failure in one repo doesn't stop the others. Problems with the two files
are reported first but don't stop the pull; with `--no-check` they aren't
looked for, but a directory that isn't a nested repo is still skipped. Git
runs with your terminal, so ssh can still ask for a passphrase.

### `push-nested [--origin-only] [--parent]`

For each nested repo in `.gitrepos`, under a `== /alpha/` header, pushes the
current branch (`git push <remote> <branch>`) to **every remote** it has;
`--origin-only` pushes only to the remote named `origin`.
It never forces: if a remote has commits you don't, the push is refused
and reported, and you pull first.

- **Upstream:** if the remote named `origin` exists and the branch has no
  upstream yet, the push to `origin` is `git push -u origin <branch>`, so
  `origin/<branch>` becomes its upstream: `origin/master` when you're on
  `master`, the usual case. An upstream already set (to any
  remote) is left alone.
- **Skipped, with a warning:** a directory that's missing or isn't a nested
  repo, a detached HEAD, a repo with no `origin` under `--origin-only`, and a
  repo on a different branch from the one `.gitrepos` means. For the last,
  switch branch or record the new one with `add-nested --branch`, then run
  `push-nested` again; nothing is switched for you.
- **Uncommitted changes** get a note: only what's committed is pushed.
- **`--parent`** also pushes the parent directory itself, after the nested
  repos, by the same rules.
- **`--no-check`** leaves out the report on the two files that comes
  before the pushes. The skips above still happen: they decide whether a
  repo can be pushed.

Design: `docs/push-nested-proposal.md`.

### `check-nested`

Reports problems with `.gitignore` and `.gitrepos`, and with the nested
repos they list on disk (missing, not a repository, no remote with the
listed url). It never uses the network, and prints nothing when there's
nothing to report. With `--fix` it repairs what it can, writes both files,
and prints `fixed N problem(s)`. `--no-check` is bad usage here (exit
status 2), since checking is all `check-nested` does. The message names
the `-r` and `-f` you gave with it (or only `--fix`, if you gave that
too).

It also reports each git repository directly in the parent directory that
`.gitrepos` doesn't list. `--fix` registers it, as `add-nested <dir>` would
(the url of `origin`, and the branch only when `add-nested` would record
it), and prints `added /<dir>/ <url>` (and the branch, if recorded) for
each one, counting them in `fixed N problem(s)`:

- **Not reported:** a directory that any `.gitignore` line names, inside the
  managed block or outside it, in any slash form (`household`,
  `/household/`). Writing such a line by hand is how you keep a repository
  there on purpose. Lines with wildcards (`*`, `?`, `[`) don't count.
- **Also not reported:** names starting with `.`, and anything that isn't a
  directory. A symbolic link to a repository is reported.
- **Only direct subdirectories** are looked at, unless you give `-r`.
- **`-r` / `--recursive`** looks deeper. It walks into every directory,
  repositories included, except directories whose name starts with `.` and
  directories that a `.gitignore` line names. That includes the `.gitignore`
  files it meets on the way, each line relative to its own folder, and the
  managed block, so listed repositories aren't walked into. It follows
  symbolic links, and enters each directory only once, so a link loop
  can't trap it. A repository found below the top belongs to its nearest
  enclosing parent: the nearest directory above it that is a git
  repository or has a `.gitrepos`, or else the `-C` directory. It counts
  as listed when that parent's `.gitrepos` lists it, with the path
  relative to that parent. `--fix` registers it only when that parent is
  the `-C` directory. Otherwise the warning says to run `check-nested -C
  <that directory> --fix` (with `-r` when it's deeper than a direct
  subdirectory there), so one run never writes into another repository's
  files. A directory it can't list, or a nested `.gitrepos` it can't read,
  is a warning, and the walk goes on.
- **`-f` / `--force`, with `-r`,** also walks into the directories that a
  `.gitignore` line names, listed repositories included. Such a directory
  is still not reported itself, but the repositories inside it are, by the
  same nearest-enclosing-parent rule. So `check-nested -r -f` finds a
  repository you put inside `/household/`, and one inside a listed
  repository that its `.gitrepos` doesn't list. When the walk had to go
  through a named directory to reach it, the warning's suggested command
  says `-r -f` too. Without `-r`, `-f` has no effect, and you get a
  warning saying so.
- **`--fix` can't register** a repository with no `origin` remote, or one
  on a detached HEAD. The warning stays, and says to use `add-nested --url`
  or `add-nested --branch`. Registering doesn't use the network either, so
  the branch rule works from `origin`'s branches as of your last fetch.

### `remove-nested <nested directory>...`

Removes each nested directory from `.gitrepos` and from the managed block of
`.gitignore`, printing `removed /alpha/ from ...` for each. **It never
deletes a directory**; if one is still on disk, the message says so. A
directory in neither file gets a warning, and the others are still removed.
The files are only rewritten if something changed. Afterwards it reports
the problems left in the two files, unless you give `--no-check`.

## Debugging

The programs are built with debug information (`-gf -debug`), so they can be
stepped through in GDB, or in Kate's debugger, which runs GDB.

GDB shows a D array as its raw parts, `length` and `ptr`, and runs D strings
into each other because they have no terminating NUL. `gdb/d_arrays.py` fixes
that: with it loaded, `string[] args` shows as its elements, `"alpha"`,
`"beta"`, and any other D array (`int[]`, `string[][]`, ...) as its elements
too. To load it whenever GDB starts, add this line to your `~/.gdbinit`,
using the path of your clone:

```
source ~/git-stuff/gdb/d_arrays.py
```

A plain `print args` uses it straight away, and so does Kate's debugger: its
"Locals and Stack" view shows `args` as its elements. (A front end's
variables view uses it only if the front end turns on pretty-printing,
`-enable-pretty-printing` in GDB's machine interface; Kate does.)

This is the one Python file meant to stay: GDB can only be extended in Python.

## `bin/ls-repos`

A bash script, not built by `make`: it lists every git repository below the
current directory (following symbolic links), each with its `origin` url,
sorted by path.

## Source files

The D code, with its designs in `docs/nested-repos-design.md` (the classes),
`docs/nested-commands-proposal.md` (the commands) and `docs/result-types.md`
(how functions report failures):

| File | What it holds |
|---|---|
| `addNested.d`, `pullNested.d`, `pushNested.d`, `checkNested.d`, `removeNested.d` | The five commands. Each does its work in a `run()` function; `main()` only calls it. |
| `nestedCommon.d` | What the commands share: exit statuses, option parsing, printing findings, the branch rules, cloning, and a few git queries. |
| `parentDirectory.d` | `ParentDirectory`: both files of a parent directory together (add, remove, check, fix, write), and the checks on disk. |
| `gitIgnore.d` | `GitIgnore`: one `.gitignore`, split around the managed block. |
| `gitRepos.d` | `GitRepos`: one `.gitrepos`, and its escaping. |
| `finding.d` | `Finding`: one problem reported by a check. |
| `textFile.d` | Reading files and writing them atomically (temporary file, then rename). |
| `gitCloneDirectoryName.d` | The directory name `git clone` would choose for a url, a port of `git_url_basename()` in git's [`dir.c`](https://github.com/git/git/blob/master/dir.c). |
| `debugio.d` | Linked into every program; see [Building](#building). |
| `gdb/d_arrays.py` | GDB pretty-printers for D arrays; see [Debugging](#debugging). |

## Tests

```bash
make test
```

This compiles and runs the D `unittest` blocks in all the files above (not
`debugio.d`, which has none). The commands are
tested in-process, by calling their `run()` functions against local
repositories in a temporary directory, so no network or SSH key is needed.
Then `make test` builds each command (the `COMMANDS` list in the `Makefile`)
and checks that `--help` exits 0 and an unknown option exits 2, which covers
the one-line `main()` the in-process tests leave out.

## Planned work

Tracked as GitHub issues. The one being worked on carries the label
[`current`](https://github.com/pflagerd/git-stuff/labels/current), and its
description holds the steps as a checklist.

- [#15](https://github.com/pflagerd/git-stuff/issues/15) Make `check-nested`
  report git repositories in the parent directory that `.gitrepos` doesn't
  list (proposal in `docs/unlisted-repos-proposal.md`). The current issue.
- [#25](https://github.com/pflagerd/git-stuff/issues/25) Bug:
  `checkRepository()` crashes on a `.gitrepos` entry that is a dangling
  symbolic link.
- [#22](https://github.com/pflagerd/git-stuff/issues/22) Let `check-nested
  --fix` apply some fixes, not all.
- [#23](https://github.com/pflagerd/git-stuff/issues/23) Number the findings
  `check-nested` lists.
- [#24](https://github.com/pflagerd/git-stuff/issues/24) Compare the old
  `add_nested.d.todo` and `pull_nested.d.todo` notes with the unit tests.
- [#7](https://github.com/pflagerd/git-stuff/issues/7) Check that the
  directories named by `.gitignore` lines outside the managed block still
  exist.
- [#4](https://github.com/pflagerd/git-stuff/issues/4) A utility to create
  remote repositories (one or several) on the owner's servers, instead of by
  hand over ssh.
- [#21](https://github.com/pflagerd/git-stuff/issues/21) Return `Nullable`
  instead of `""` from functions that may have no value to give.
- [#18](https://github.com/pflagerd/git-stuff/issues/18) Remove `python3`
  from `setup.sh`, now that the Python scripts are gone.
