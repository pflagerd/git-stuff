# git-stuff

We want nested git repositories which are cloned to, checked out from, pulled
from, and pushed to their own remotes when the parent repository is cloned,
checked out, pulled and pushed.

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

### Building

```bash
make
```

This builds `bin/add-nested` and `bin/pull-nested` with debug output and
unit tests compiled in. `make clean` removes them.

The `Makefile` calls `dmd`, the reference D compiler. Ubuntu doesn't package
`dmd`; it is available from [dlang.org](https://dlang.org/download.html).
The open-source LLVM-based compiler [LDC](https://github.com/ldc-developers/ldc)
is packaged (`sudo apt install ldc`) and its `ldmd2` wrapper accepts the same
flags, so you can build the same way with it:

```bash
ldmd2 -wi -gf -unittest -debug add_nested.d debugio.d -of=bin/add-nested
ldmd2 -wi -gf -unittest -debug pull_nested.d debugio.d gitCloneDirectoryName.d -of=bin/pull-nested
```

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
  (`//alpha/`).
- **`add-nested` only handles its first argument.** An unconditional `break`
  in `main()`'s loop stops after one argument, even though the usage text
  says it accepts several.
- **`add-nested` doesn't save updated `.gitrepos` entries.** When an entry
  already exists and its branch has changed, the updated line is never
  written back to the file.
- **`find_and_remove_desktop_directories_not_in_%2Egitrepos.py` doesn't
  really check `.gitrepos`.** It saves only the first character of each line
  and compares those against `Path` objects, so no directory ever counts as
  listed. Apart from the y/N prompt, the only safeguard against deleting a
  directory that *is* listed is the separate git work-tree and
  `git check-ignore` test in `git_ignored()`, and what that test decides
  depends on the directory you run it from.
- **`bin/commit-and-push` has no `#!` line**, so it runs under whatever shell
  calls it.
