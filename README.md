# git-stuff

We want nested git repositories which are cloned to, checked out from, pulled
from, and pushed to their own remotes when the parent repository is cloned,
checked out, pulled and pushed.

These utilities are for Linux only.

Git's own answer to this is
[submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules), which pin
each nested repo to a specific commit. This project takes a lighter approach:
the parent repo ignores each nested repo in `.gitignore` and lists it, with its
remote URL and branch, in a plain-text `.gitrepos` file. The tools here read
and write those two files.

## Files the tools use

These live in the **parent** repository, not in this one.

### `.gitrepos`

One line per nested repository, sorted, with fields separated by spaces:

```
<directory> <remote-url> [<branch>]
```

- `<directory>` is relative to the parent repo, written with a leading and
  trailing `/` (e.g. `/alpha/`).
- `<remote-url>` is what `git clone` is given.
- `<branch>` is optional. Leave it out for `master` or `main`.

Example:

```
/alpha/ git@github.com:pflagerd/alpha.git
/beta/ git@github.com:pflagerd/beta.git dev
```

### `.gitignore`

Each nested directory is also listed in the parent's `.gitignore` (e.g.
`/alpha/`), so the parent repo doesn't track the nested repo's files.

### `.forks`

`.forks` records which other repositories were forked from this one. Its
format is described in the comments at the top of the file.

## The D tools

### Setup

```bash
make setup
```

This runs `./setup.sh`, which installs whichever of these Ubuntu packages are
missing: `ldc` (the D compiler), `make`, `git` and `python3` (for the
remaining Python scripts, until [#18](https://github.com/pflagerd/git-stuff/issues/18)). It uses `apt-get` (via `sudo` unless run as root), and apt
asks before installing anything. Run it again at any time; it installs only
what's missing.

On a machine without `make`, run `./setup.sh` directly.

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

This builds `bin/add-nested`, `bin/pull-nested`, `bin/check-nested` and
`bin/remove-nested` with debug output compiled in. Every one is linked with
`debugio.d`, which in these `-debug` builds makes standard output
unbuffered, so output appears line by line when stepping through a program
in Kate's debugger. Unit tests are not compiled into them; `make test`
runs those. `make clean` removes them. `bin/.gitignore` keeps the
built programs out of git.

The compiler is set by the `DC` variable, which defaults to `ldmd2`: the
wrapper of the open-source LLVM-based compiler
[LDC](https://github.com/ldc-developers/ldc) that accepts the flags of `dmd`,
the reference D compiler. To build with `dmd` instead (not packaged by
Ubuntu; available from [dlang.org](https://dlang.org/download.html)):

```bash
make DC=dmd
```

### `check-nested [-C <directory>] [--fix]`

Reports problems with a parent directory's `.gitignore` and `.gitrepos`, and
with the nested repos they list, as `warning:` lines on standard error. It
never uses the network. It prints nothing when there's nothing to report.

- `-C <directory>`: check that parent directory instead of the current one.
- `--fix`: first repair what can be repaired (sort, de-duplicate, move nested
  repo lines into the managed block, add missing block entries), write both
  files, and print `fixed N problem(s)`.

Exit status: 0 no problems, 1 problems remain, 2 bad usage or a file that
can't be read. Source: `checkNested.d`, on top of the classes described in
`docs/nested-repos-design.md`.

### `remove-nested [-C <directory>] [--fix] <nested directory>...`

Removes each nested directory (in any slash form: `alpha`, `/alpha/`, ...)
from `.gitrepos` and from the managed block of `.gitignore`, printing
`removed /alpha/ from ...` for each. **It never deletes a directory**; if one
is still on disk, the message says so. A directory in neither file gets a
warning, and the others are still removed. The files are only rewritten if
something changed. Afterwards, any remaining problems with the two files are
reported as with `check-nested`.

Exit status: 0 done, 1 something wasn't registered or problems remain, 2 bad
usage or a file that can't be read. Source: `removeNested.d`.

### `add-nested [-C <directory>] [--fix] [--branch <name>] [--url <url>] <nested directory>...`

Registers each nested directory, an existing clone given relative to the
parent directory (`alpha`, `/alpha/`, `tools/alpha`; no `.` or `..`), in
`.gitrepos` and in the managed block of `.gitignore`, printing
`added /alpha/ <url> [<branch>]` for each.

- **Every argument is checked first; if any fails, nothing is written.**
  Each must be the top level of its own git repository and have a url and a
  branch. Every problem is reported, not just the first.
- **url:** the stored `remote.origin.url`, or `--url`.
- **branch:** the current branch, or `--branch` (needed for a detached
  HEAD). The current branch is left out of `.gitrepos` only when
  `pull-nested` would arrive at it by itself from a fresh clone (see
  decision 3 in `docs/nested-commands-proposal.md`); `--branch` is always
  recorded.
- `--branch` and `--url` need exactly one nested directory.
- Afterwards, remaining problems with the two files are reported as with
  `check-nested`.

`add-nested [-C <directory>] [--fix] [--branch <name>] --clone <url> [<nested directory>]`
clones `<url>` first, into the nested directory given or else the one
`git clone` would choose, then registers it as above. Everything that can be
checked without the network is checked first (both files, the directory
rules, and that the directory doesn't exist yet), so a mistake costs no
download. The clone gets the branch `pull-nested` would give it: `--branch`,
else a branch named after the directory if the remote has one, else the
default. If the clone succeeds but the branch can't be checked out, the clone
is kept, unregistered, and the message says how to register it.

Exit status: 0 done, 1 an argument failed or problems remain, 2 bad usage or
a file that can't be read. Source: `addNested.d`.

### `pull-nested [-C <directory>] [--fix]`

For each nested repo in `.gitrepos`, under a `== /alpha/` header, with git's
own messages shown as they happen:

- **Missing:** `git clone <url> <directory>`, then checks out the listed
  branch. With no branch listed, if the directory's name differs from the
  name `git clone` would choose, it checks out a branch named after the
  directory if the remote has one, and otherwise stays on the remote's
  default branch, saying so.
- **Exists but isn't a nested repo:** a warning; skipped.
- **Exists:** `git pull --ff-only`, which only ever moves the branch forward;
  if the branch has diverged it refuses and leaves the repo as it was,
  whatever her `pull.*` settings say. **It never switches branches** in an
  existing repo: if she's on a different branch from the one `.gitrepos`
  means, it warns and pulls the branch she's on.

A failure in one repo doesn't stop the others. Problems with `.gitignore` and
`.gitrepos` are reported first but don't stop the pull; `--fix` repairs them
first. Exit status: 0 done, 1 a repo failed or problems remain, 2 bad usage or
a file that can't be read. Git runs with its terminal, so ssh can still ask
for a passphrase.

`gitCloneDirectoryName.d` works out the name `git clone` would choose. It is
a port of `git_url_basename()` in git's
[`dir.c`](https://github.com/git/git/blob/master/dir.c). Source:
`pullNested.d`.

## Bash helpers in `bin/`

These are short wrappers around git. Some call each other (for example,
`add-commit-push` calls `commit-and-push`, which calls `push`), so `bin/` needs
to be on your `PATH`.

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
decides its fate.

All need Python 3 and git, and use only the standard library.

These take paths as arguments (defaulting to `.`) and accept `-v` for verbose
output. Each exits 0 if any path matched and 1 otherwise.

- **`is_pflager_net_in_git_origin.py [paths]`** prints the paths whose
  `origin` host ends in `.pflager.net`.
- **`is_zax_pflager_net_git_origin.py [paths]`** prints the paths whose
  `origin` is `zax` or `zax.pflager.net`.
- **`add_origin_host_remote.py [paths]`** adds a second remote, named after
  the `origin` host, wherever one doesn't already exist.

These three: [#17](https://github.com/pflagerd/git-stuff/issues/17).

The rest read `../.gitrepos` or `../.gitignore`, so they expect to be run from
a directory one level below the parent repo:

- **`look_for_missing_remotes.py`** prints each `.gitrepos` entry whose remote
  can't be reached (`git ls-remote` fails). [#14](https://github.com/pflagerd/git-stuff/issues/14)
- **`find_desktop_directories_not_in_%2Egitrepos.py`** prints the directories
  in `..` that `.gitrepos` doesn't list. [#15](https://github.com/pflagerd/git-stuff/issues/15)
- **`find_directories_in_%2Egitignore_not_on_disk.py`** prints the
  `.gitignore` entries that have no matching directory in `..`. [#16](https://github.com/pflagerd/git-stuff/issues/16)
- **`find_and_remove_desktop_directories_not_in_%2Egitrepos.py`** offers to
  delete (with a y/N prompt for each) the directories in `..` that aren't
  listed in `.gitrepos`. **Read the known issues before running it.** [#11](https://github.com/pflagerd/git-stuff/issues/11)

`%2E` in the file names is the URL encoding of `.`.

## Tests

```bash
make test
```

This compiles and runs the D `unittest` blocks in the modules being built
from `docs/nested-repos-design.md`:

- `gitIgnore.d`: the `GitIgnore` class, which reads, checks and writes a
  `.gitignore`.
- `gitRepos.d`: the `GitRepos` class, which reads, checks, adds to, removes
  from and writes a `.gitrepos`.
- `parentDirectory.d`: the `ParentDirectory` class, which reads, writes, adds
  to, removes from, checks and fixes both files of a directory together, and
  checks the nested repos on disk.
- `addNested.d`, `checkNested.d`, `pullNested.d` and `removeNested.d`: the
  four commands, tested in-process through
  their `run()` functions against local repositories (no network or SSH
  key needed).
- `nestedCommand.d`: what the commands share: exit statuses, option parsing,
  printing findings, the branch rules and a few git queries.
- `finding.d`: the `Finding` struct that checks return.
- `textFile.d`: the shared reading and atomic writing.

After the unit tests, `make test` builds each new command (the `COMMANDS`
list in the `Makefile`) and checks that `--help` exits 0 and an unknown
option exits 2, which covers the one-line `main()` the in-process tests
leave out.

## Planned work

Tracked as GitHub issues:

- [#13](https://github.com/pflagerd/git-stuff/issues/13) Review this README end to end.
- [#7](https://github.com/pflagerd/git-stuff/issues/7) Check that the directories named by `.gitignore` lines outside the
  managed block still exist.
- [#1](https://github.com/pflagerd/git-stuff/issues/1) Let `add-commit-push` and `commit-and-push` take `-m` to override
  the default `progress` message.
- [#4](https://github.com/pflagerd/git-stuff/issues/4) A utility to create remote repositories (one or several) on the owner's
  servers, instead of by hand over ssh.
- Replace the Python scripts with D, or delete them: [#14](https://github.com/pflagerd/git-stuff/issues/14), [#15](https://github.com/pflagerd/git-stuff/issues/15),
  [#16](https://github.com/pflagerd/git-stuff/issues/16), [#17](https://github.com/pflagerd/git-stuff/issues/17) and [#11](https://github.com/pflagerd/git-stuff/issues/11); then [#18](https://github.com/pflagerd/git-stuff/issues/18) removes `python3` from
  `setup.sh`.

Bugs are listed under [Known issues](#known-issues). The designs are in
`docs/nested-repos-design.md` and `docs/nested-commands-proposal.md`.

## Known issues

- **`find_and_remove_desktop_directories_not_in_%2Egitrepos.py` doesn't
  really check `.gitrepos`.** It saves only the first character of each line
  and compares those against `Path` objects, so no directory ever counts as
  listed. Apart from the y/N prompt, the only safeguard against deleting a
  directory that *is* listed is the separate git work-tree and
  `git check-ignore` test in `git_ignored()`, and what that test decides
  depends on the directory you run it from. ([#11](https://github.com/pflagerd/git-stuff/issues/11))
- **`bin/commit-and-push` has no `#!` line**, so it runs under whatever shell
  calls it. ([#12](https://github.com/pflagerd/git-stuff/issues/12))
