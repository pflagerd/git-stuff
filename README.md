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
6. `check-nested --fix` repairs what it can in `.gitignore` and `.gitrepos`
   and reports anything else.

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
entries in one managed block and never change anything outside it, so your own
lines, comments and their order are left alone:

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
missing: `ldc` (the D compiler), `make`, `git` and `python3` (for the
remaining Python scripts, until
[#18](https://github.com/pflagerd/git-stuff/issues/18)). It uses `apt-get`
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
| `-h`, `--help` | Print usage. |

| Exit status | Meaning |
|---|---|
| 0 | Did its job, and no problems remain. |
| 1 | Did what it could, but problems remain or something failed for some repo or argument. |
| 2 | Couldn't start: bad usage, or `.gitignore`/`.gitrepos` couldn't be read; nothing was changed. |

Problems are printed as `warning:` lines on standard error, marked
`(fixable with --fix)` where that applies. Nested directories are given
relative to the parent directory, in any slash form (`alpha`, `/alpha/`,
`tools/alpha`); `.` and `..` aren't allowed. Afterwards, each command
reports any problems left in the two files, as `check-nested` would. Git
always runs with an argument list, never through a shell, so names with
spaces are safe.

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
are reported first but don't stop the pull. Git runs with your terminal, so
ssh can still ask for a passphrase.

### `push-nested [--origin-only] [--parent]`

For each nested repo in `.gitrepos`, under a `== /alpha/` header, pushes the
current branch (`git push <remote> <branch>`) to **every remote** it has, as
`bin/push` does; `--origin-only` pushes only to the remote named `origin`.
It never forces: if a remote has commits you don't, the push is refused
and reported, and you pull first.

- **Upstream:** if the remote named `origin` exists and the branch has no
  upstream yet, the push to `origin` is `git push -u origin <branch>`, so
  `origin/<branch>` becomes its upstream. An upstream already set (to any
  remote) is left alone.
- **Skipped, with a warning:** a directory that's missing or isn't a nested
  repo, a detached HEAD, a repo with no `origin` under `--origin-only`, and a
  repo on a different branch from the one `.gitrepos` means. For the last,
  switch branch or record the new one with `add-nested --branch`, then run
  `push-nested` again; nothing is switched for you.
- **Uncommitted changes** get a note: only what's committed is pushed.
- **`--parent`** also pushes the parent directory itself, after the nested
  repos, by the same rules.

Design: `docs/push-nested-proposal.md`.

### `check-nested`

Reports problems with `.gitignore` and `.gitrepos`, and with the nested
repos they list on disk (missing, not a repository, no remote with the
listed url). It never uses the network, and prints nothing when there's
nothing to report. With `--fix` it repairs what it can, writes both files,
and prints `fixed N problem(s)`.

### `remove-nested <nested directory>...`

Removes each nested directory from `.gitrepos` and from the managed block of
`.gitignore`, printing `removed /alpha/ from ...` for each. **It never
deletes a directory**; if one is still on disk, the message says so. A
directory in neither file gets a warning, and the others are still removed.
The files are only rewritten if something changed.

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

## Bash helpers in `bin/`

These are short wrappers around git. Some call each other (for example,
`add-commit-push` calls `commit-and-push`, which calls `push`), so `bin/`
needs to be on your `PATH`.

| Script | What it does |
|---|---|
| `add [args]` | `git add [args]` |
| `commit [message]` | `git commit -a` with the message, or `progress` if none is given |
| `commit-and-push [message]` | `commit`, then `push` |
| `add-commit-push [message]` | `git add .`, then `commit-and-push` |
| `push` | `git push` to **every** remote that has a push URL |
| `pull [args]` | `git pull [args]` |
| `fetch [args]` | `git fetch [args]` |
| `remotes` | `git remote -v` |
| `rev` | Prints the current commit (`git rev-parse HEAD`) |
| `ls-repos` | Lists every nested git repo below the current directory with its `origin` URL |

`bin/add-repo-to-desktop`, `bin/pull-desktop-repos` and `bin/template` are
compiled x86-64 programs (built with `dmd`) whose source is not in this
repository.

## Python scripts

These are being replaced by D or deleted; each links to the issue that
decides its fate. All need Python 3 and git, and use only the standard
library.

These take paths as arguments (defaulting to `.`) and accept `-v` for verbose
output. Each exits 0 if any path matched and 1 otherwise
([#17](https://github.com/pflagerd/git-stuff/issues/17) for all three):

- **`is_pflager_net_in_git_origin.py [paths]`** prints the paths whose
  `origin` host ends in `.pflager.net`.
- **`is_zax_pflager_net_git_origin.py [paths]`** prints the paths whose
  `origin` is `zax` or `zax.pflager.net`.
- **`add_origin_host_remote.py [paths]`** adds a second remote, named after
  the `origin` host, wherever one doesn't already exist.

The rest read `../.gitrepos` or `../.gitignore`, so they expect to be run from
a directory one level below the parent directory:

- **`look_for_missing_remotes.py`** prints each `.gitrepos` entry whose remote
  can't be reached (`git ls-remote` fails).
  [#14](https://github.com/pflagerd/git-stuff/issues/14)
- **`find_desktop_directories_not_in_%2Egitrepos.py`** prints the directories
  in `..` that `.gitrepos` doesn't list.
  [#15](https://github.com/pflagerd/git-stuff/issues/15)
- **`find_directories_in_%2Egitignore_not_on_disk.py`** prints the
  `.gitignore` entries that have no matching directory in `..`.
  [#16](https://github.com/pflagerd/git-stuff/issues/16)
- **`find_and_remove_desktop_directories_not_in_%2Egitrepos.py`** offers to
  delete (with a y/N prompt for each) the directories in `..` that aren't
  listed in `.gitrepos`. **Read the known issues before running it.**
  [#11](https://github.com/pflagerd/git-stuff/issues/11)

`%2E` in the file names is the URL encoding of `.`.

## Source files

The D code, with its designs in `docs/nested-repos-design.md` (the classes)
and `docs/nested-commands-proposal.md` (the commands):

| File | What it holds |
|---|---|
| `addNested.d`, `pullNested.d`, `pushNested.d`, `checkNested.d`, `removeNested.d` | The five commands. Each does its work in a `run()` function; `main()` only calls it. |
| `nestedCommand.d` | What the commands share: exit statuses, option parsing, printing findings, the branch rules, cloning, and a few git queries. |
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
`gitCloneDirectoryName.d` or `debugio.d`, which have none). The commands are
tested in-process, by calling their `run()` functions against local
repositories in a temporary directory, so no network or SSH key is needed.
Then `make test` builds each command (the `COMMANDS` list in the `Makefile`)
and checks that `--help` exits 0 and an unknown option exits 2, which covers
the one-line `main()` the in-process tests leave out.

## Planned work

Tracked as GitHub issues:

- [#7](https://github.com/pflagerd/git-stuff/issues/7) Check that the
  directories named by `.gitignore` lines outside the managed block still
  exist.
- [#1](https://github.com/pflagerd/git-stuff/issues/1) Let `add-commit-push`
  and `commit-and-push` take `-m` to override the default `progress` message.
- [#4](https://github.com/pflagerd/git-stuff/issues/4) A utility to create
  remote repositories (one or several) on the owner's servers, instead of by
  hand over ssh.
- Replace the Python scripts with D, or delete them:
  [#14](https://github.com/pflagerd/git-stuff/issues/14),
  [#15](https://github.com/pflagerd/git-stuff/issues/15),
  [#16](https://github.com/pflagerd/git-stuff/issues/16),
  [#17](https://github.com/pflagerd/git-stuff/issues/17) and
  [#11](https://github.com/pflagerd/git-stuff/issues/11); then
  [#18](https://github.com/pflagerd/git-stuff/issues/18) removes `python3`
  from `setup.sh`.

Bugs are listed under [Known issues](#known-issues).

## Known issues

- **`find_and_remove_desktop_directories_not_in_%2Egitrepos.py` doesn't
  really check `.gitrepos`.** It saves only the first character of each line
  and compares those against `Path` objects, so no directory ever counts as
  listed. Apart from the y/N prompt, the only safeguard against deleting a
  directory that *is* listed is the separate git work-tree and
  `git check-ignore` test in `git_ignored()`, and what that test decides
  depends on the directory you run it from.
  ([#11](https://github.com/pflagerd/git-stuff/issues/11))
