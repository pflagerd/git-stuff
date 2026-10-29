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
missing: `ldc` (the D compiler), `make`, `git`, `python3` and
`python3-pytest`. It uses `apt-get` (via `sudo` unless run as root), and apt
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

This builds `bin/add-nested`, `bin/pull-nested` and `bin/check-nested` with
debug output compiled in. Unit tests are not compiled into them; `make test`
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

### `add-nested <directory | url> ...`

Run from the parent repo. For an existing nested clone, it adds the directory
to `.gitignore` and adds `<directory> <origin url> [<branch>]` to `.gitrepos`,
keeping both files sorted. Given a URL, it uses the last path segment of the
URL as the directory name, and that directory must already exist.

Source: `add_nested.d`. **Currently broken**; see [Known issues](#known-issues).

### `pull-nested`

Run from the parent repo. For each line of `.gitrepos`:

- If the directory doesn't exist, it runs `git clone <url> <directory>`.
- If the directory exists, it runs `git -C <directory> pull`.
- If a branch is given, or the directory name differs from the name
  `git clone` would choose, it checks out that branch. When no branch is
  given, the branch name is taken to be the directory name.

`gitCloneDirectoryName.d` works out the name `git clone` would choose. It is
a port of `git_url_basename()` in git's
[`dir.c`](https://github.com/git/git/blob/master/dir.c).

Source: `pull_nested.d`.

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

These are being replaced by D or deleted; the plan is in `TODO`.

All need Python 3 and git, and use only the standard library.

These take paths as arguments (defaulting to `.`) and accept `-v` for verbose
output. Each exits 0 if any path matched and 1 otherwise.

- **`is_pflager_net_in_git_origin.py [paths]`** prints the paths whose
  `origin` host ends in `.pflager.net`.
- **`is_zax_pflager_net_git_origin.py [paths]`** prints the paths whose
  `origin` is `zax` or `zax.pflager.net`.
- **`add_origin_host_remote.py [paths]`** adds a second remote, named after
  the `origin` host, wherever one doesn't already exist.

The rest read `../.gitrepos` or `../.gitignore`, so they expect to be run from
a directory one level below the parent repo:

- **`look_for_missing_remotes.py`** prints each `.gitrepos` entry whose remote
  can't be reached (`git ls-remote` fails).
- **`find_desktop_directories_not_in_%2Egitrepos.py`** prints the directories
  in `..` that `.gitrepos` doesn't list.
- **`find_directories_in_%2Egitignore_not_on_disk.py`** prints the
  `.gitignore` entries that have no matching directory in `..`.
- **`find_and_remove_desktop_directories_not_in_%2Egitrepos.py`** offers to
  delete (with a y/N prompt for each) the directories in `..` that aren't
  listed in `.gitrepos`. **Read the known issues before running it.**

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
- `checkNested.d`: the `check-nested` command, tested in-process through its
  `run()` function.
- `nestedCommand.d`: what the commands share: exit statuses, option parsing,
  printing findings, the branch rules and a few git queries.
- `finding.d`: the `Finding` struct that checks return.
- `textFile.d`: the shared reading and atomic writing.

After the unit tests, `make test` builds each new command (the `COMMANDS`
list in the `Makefile`) and checks that `--help` exits 0 and an unknown
option exits 2, which covers the one-line `main()` the in-process tests
leave out.

`test_add_nested.py` lists the planned test cases for `add-nested` in comments.
One case is written so far, and it clones `git@github.com:pflagerd/a.git`, so
it needs SSH access to GitHub.

## Planned work

See `TODO`. The plan is to parse `.gitignore` and `.gitrepos` into data
structures, check their syntax, sort order and agreement with each other, and
then do the `add-nested` and `pull-nested` work on those structures.

## Known issues

- **`add-nested` fails on relative paths.** It prepends `/` to the directory
  name and then runs `git -C /<directory>/`, which looks in the filesystem
  root, so `add-nested alpha` fails with `cannot change to '/alpha/'`. It also
  writes the entry to `.gitignore` before failing, with a doubled slash
  (`//alpha/`). ([#8](https://github.com/pflagerd/git-stuff/issues/8))
- **`add-nested` only handles its first argument.** An unconditional `break`
  in `main()`'s loop stops after one argument, even though the usage text
  says it accepts several. ([#9](https://github.com/pflagerd/git-stuff/issues/9))
- **`add-nested` doesn't save updated `.gitrepos` entries.** When an entry
  already exists and its branch has changed, the updated line is never
  written back to the file. ([#10](https://github.com/pflagerd/git-stuff/issues/10))
- **`find_and_remove_desktop_directories_not_in_%2Egitrepos.py` doesn't
  really check `.gitrepos`.** It saves only the first character of each line
  and compares those against `Path` objects, so no directory ever counts as
  listed. Apart from the y/N prompt, the only safeguard against deleting a
  directory that *is* listed is the separate git work-tree and
  `git check-ignore` test in `git_ignored()`, and what that test decides
  depends on the directory you run it from. ([#11](https://github.com/pflagerd/git-stuff/issues/11))
- **`bin/commit-and-push` has no `#!` line**, so it runs under whatever shell
  calls it. ([#12](https://github.com/pflagerd/git-stuff/issues/12))
