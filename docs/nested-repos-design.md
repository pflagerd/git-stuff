# Nested repos: design

Status: **design agreed, not yet implemented.** Branch: `gitignore-serialization`.

This document records the design for reading, checking and writing the two
files that describe a parent directory's nested repositories: `.gitignore`
and `.gitrepos`. It replaces the `.gitignore.serialize()` /
`.gitignore.deserialize()` sketch in `TODO`.

It will fix [#8](https://github.com/pflagerd/git-stuff/issues/8) (add-nested
breaks relative paths), [#5](https://github.com/pflagerd/git-stuff/issues/5)
(leading `/` in `.gitrepos`) and [#3](https://github.com/pflagerd/git-stuff/issues/3)
(spaces in names), and covers the checks asked for in
[#6](https://github.com/pflagerd/git-stuff/issues/6) and
[#7](https://github.com/pflagerd/git-stuff/issues/7).

## Overview

Three classes, each in its own `.d` file, each a top-level module (not inside
any package), following the precedent of `gitCloneDirectoryName.d`. File and
module names are camelCase like that precedent. The D style guide prefers
all-lowercase module names to avoid trouble on case-insensitive file systems
([D style](https://dlang.org/dstyle.html)), but these utilities are for Linux
only, where file systems are case-sensitive.

| Class | File | Represents |
|---|---|---|
| `GitIgnore` | `gitIgnore.d` | One `.gitignore` file |
| `GitRepos` | `gitRepos.d` | One `.gitrepos` file |
| `ParentDirectory` | `parentDirectory.d` | A directory holding nested repos, with its `GitIgnore` and `GitRepos` |
| `Finding` (struct) | `finding.d` | One problem reported by any class's `check()` |
| (functions) | `textFile.d` | Shared file handling: `readIfExists`, `splitFileLines` (`\n` only, final newline remembered), `writeAtomically` (temporary file + rename, permissions kept) |

`GitIgnore` and `GitRepos` do not know about each other: neither imports the
other. Anything that needs both files lives in `ParentDirectory`. This keeps
each file class testable on its own and stops a change to one file format
breaking the other.

The parent directory **need not be a git repository.** It may be a plain
directory (e.g. a Desktop folder) that groups repos.

## Shared conventions

- **Reading happens in the constructor.** A constructed object always holds a
  fully parsed file; there is no separate `deserialize()` and no
  "constructed but not yet read" state.
- **The constructor takes an optional path.** Default: the file of that name
  in the current directory (`.gitignore`, `.gitrepos`). A missing file is not
  an error; it reads as empty.
- **The object remembers the path it was read from** (an `immutable` field).
- **`write()` writes back to that path** unless given an explicit path. It is
  a `const` method: writing never changes the object.
- **Writes are atomic per file:** write a temporary file in the same
  directory, then `rename()` it over the original, so an interrupted write
  never leaves a truncated file. ([POSIX rename](https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html),
  [std.file.rename](https://dlang.org/phobos/std_file.html#rename))
- **Re-reading means a new object.** Read-only fields can only be set in the
  constructor ([D spec: class fields](https://dlang.org/spec/class.html#fields)),
  so `--fix` and any re-read build a new object rather than mutating one.

## `GitIgnore`

### File format

`.gitignore` is shared with people, so the tool owns only one fenced block
and never touches anything else:

```
.idea/
*.o
# BEGIN nested repos (managed by add-nested)
/alpha/
/beta/
# END nested repos
tmp/
```

The marker lines must be exactly as above. Git treats only lines that
*start* with `#` as comments ([gitignore docs](https://git-scm.com/docs/gitignore)),
so the markers must be lines of their own.

### Fields

| Field | Mutable? | Contents |
|---|---|---|
| `path` | no (`immutable`) | Where it was read from; `write()`'s default |
| `before` | no (`immutable`) | Lines before the BEGIN marker, exactly as read |
| `nested` | yes | Patterns inside the block, kept sorted |
| `after` | no (`immutable`) | Lines after the END marker, exactly as read |
| `endsWithNewline` | no (`immutable`) | Whether the file's last line ended in `\n` (true for a missing or empty file) |

Lines are split on `\n` only, as git does. A `\r` stays part of its line, so
a CRLF file is written back unchanged, and a file without a final newline is
written back without one. Marker lines must match exactly, so in a CRLF file
`…add-nested)\r` is not a marker.

`before` and `after` are kept exactly as read, comments, blank lines and
order included. Order matters in `.gitignore` ("the last matching pattern
decides the outcome", [gitignore docs](https://git-scm.com/docs/gitignore)),
so sorting the whole file could change what is ignored when `!` negation is
used. Only `nested` is ever sorted.

### Behaviour

- **No block in the file:** everything reads as `before`, `nested` is
  empty, and the first write adds the block at the end.
- **Malformed block** (BEGIN without END, END without BEGIN, two blocks):
  refuse with a clear error. Guessing could rewrite her `.gitignore` wrongly.
- **Nothing to write:** `write()` does not create a new file that would be
  empty.
- **Written as:** `before`, BEGIN marker, `nested` (sorted, duplicates
  dropped), END marker, `after`, joined with `\n`. `content()` returns that text without writing it.
- **Empty block:** left out when `nested` is empty, so removing the last
  nested repo removes the block.
- **Final newline:** when the block is the last thing in the file, the file
  ends with `\n` (the END line is the tool's). Otherwise the original final
  newline, or lack of one, is kept.
- **Permissions:** an existing file's permission bits are copied to the
  replacement before the rename.
- **`check()`** reports, without changing anything: an unsorted block
  (fixable), an entry appearing more than once (fixable), and an entry not of
  the form `/directory/`, including one with `//` anywhere (not fixable:
  rewriting it would be a guess).
  Messages name the file's `path`; `directory` is `""` for a whole-file
  problem. Findings carry no line numbers, because the parsed object doesn't
  keep them; a malformed block, found while parsing, does report its line.

### Round trip

Reading a `.gitignore` and writing it back reproduces it byte for byte,
including CRLF lines, a missing final newline, blank lines, comments and
escapes, provided any block is already sorted, has no blank lines or repeated
entries, is not empty, and ends with `\n` if it is the last thing in the file. Otherwise the
design changes the file on purpose: the block is sorted, blank lines and
repeated entries in it are dropped, an empty block is removed, and a final newline is added after
a block at the end. `gitIgnore.d`'s unit tests check both lists.

The file must be valid UTF-8: D's `readText` rejects anything else, so such
a file fails to load rather than being rewritten.

## `GitRepos`

### File format

One line per nested repo, fields separated by single spaces:

```
<directory> <url> [<branch>]
```

```
/alpha/ git@github.com:pflagerd/alpha.git
/beta/ git@github.com:pflagerd/beta.git dev
/tools/gamma/ https://github.com/pflagerd/gamma.git
```

The whole file is tool-managed (no block). On read, blank lines and lines
starting with `#` are skipped; they are not written back. Fields are split on
runs of whitespace, so older files with double spaces or tabs still read;
the file is always written with single spaces and a final newline. Entries
keep their file order, duplicates included, so `check()` can report them.
A line with fewer than two or more than three fields is a parse error.

### Entry fields (`GitReposEntry`)

| Field | Required? | Meaning |
|---|---|---|
| `directory` | yes | Relative to the parent directory. Always written as `/alpha/`; read in any form (`alpha`, `/alpha`, `alpha/`, `/alpha/`) so existing files keep working (#5). A doubled slash anywhere (`//alpha/`, `/tools//gamma/`) is a parse error naming the line. Nested paths such as `/tools/gamma/` are allowed. |
| `url` | yes | A git URL as `git clone` defines it ([git-clone: GIT URLS](https://git-scm.com/docs/git-clone#_git_urls)): `ssh://`, `https://`, `file://`, scp-like `user@host:path`, or a local path. It must equal the fetch url of at least one remote in the nested repo (`remote.<name>.url`, as shown by `git remote -v`). No `//` except straight after a scheme (`ssh://`, `https://`; [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986#section-3)), and for `file:` one more `/` for an empty host (`file:///srv/x.git`; [RFC 8089](https://www.rfc-editor.org/rfc/rfc8089#section-2)); scp-like urls and local paths may not contain `//` at all. Otherwise a parse error. |
| `branch` | no | No `//`, which git forbids in ref names ([git-check-ref-format](https://git-scm.com/docs/git-check-ref-format)); otherwise a parse error. When given, that branch is checked out. When absent: if `directory`'s last part differs from the name `git clone` would choose (`gitCloneDirectoryName.d`), check out a branch named after the directory; otherwise use the remote's default branch. |

### Escaping (#3)

Fields are space-separated, so these characters are escaped when written,
and only these:

| Character | Written as |
|---|---|
| `%` | `%25` |
| space | `%20` |
| tab | `%09` |
| newline | `%0A` |

Reading decodes **only these four sequences**; any other `%XX` is left as
is. That keeps old, unescaped files that contain literal `%` text (such as
`%2E`) reading correctly. Because `%` is always written as `%25`, anything
the tool writes reads back exactly: `unescape(escape(s)) == s` for every
`s`, which is a natural `unittest`.

General URI encoding (`std.uri.encodeComponent`) was rejected: it also
escapes `@`, `:` and `/`, which would rewrite every ordinary line into an
unreadable form.

### Fields and operations

| Member | Notes |
|---|---|
| `path` | `immutable`; where it was read from |
| `entries` | `GitReposEntry` list, kept sorted by `directory` |
| constructor | Reads and parses `path` (default `.gitrepos`) |
| `add(entry)` | Normalizes the directory, then adds the entry, replacing every entry with the same directory (duplicates included). Throws `GitReposException` for anything `parse()` would refuse, plus an empty url, so `write()` never produces a file that won't parse. |
| `remove(directory)` | Normalizes its argument (`"alpha"` works), removes every matching entry, returns whether anything was removed. Never touches the directory on disk. |
| `content()` | The text `write()` would produce: entries sorted by directory (stable, so duplicates keep their order), fields escaped and single-space separated, branch omitted when empty, final newline; `""` for no entries |
| `write(path?)` | `const`; atomic. A missing file that would be empty is not created; an existing file whose entries were all removed is written empty, not deleted. |

Two entries with the same directory already in a file are not silently
merged on read or write. `check()` reports, without changing anything:
entries not sorted by directory (fixable: `write()` sorts), and each
directory listed more than once, with the count (not fixable: which url or
branch is right is her call). Everything else that could be wrong with a
line is refused by `parse()`.

### Round trip

A `.gitrepos` already in the tool's own format comes back byte for byte:
lines sorted by directory, each directory in `/alpha/` form, fields escaped
as `escapeField` writes them and separated by single spaces, no comments or
blank lines, and a final newline. Otherwise the tool changes the file on
purpose: comments and blank lines are dropped, runs of whitespace become
single spaces, every slash form becomes `/alpha/`, lines are sorted, a final
newline is added, a CRLF line's `\r` is dropped, and literal `%` text that
isn't one of the four escapes (e.g. `%2E`) has its `%` escaped
(`%252E`). `gitRepos.d`'s unit tests check both lists.

## `ParentDirectory`

Owns one `GitIgnore` and one `GitRepos` for a directory (default: the current
directory) and is the only place that works with both. Commands such as
`add-nested` become thin: construct a `ParentDirectory`, call one operation,
write.

`.gitignore` is maintained even when the parent directory is not a git
repository. There git does not read it ([gitignore docs](https://git-scm.com/docs/gitignore)),
but it costs nothing and is already correct if she later runs `git init`.

### Operations

| Operation | Effect |
|---|---|
| `add(directory)` | Adds the entry to `.gitrepos` and the pattern to the `.gitignore` block |
| `remove(directory)` | Removes both. **Never touches the directory on disk.** Deleting is the one irreversible action here, and it stays out of this class. |
| `check()` | Returns a list of findings; prints nothing |
| `fix()` | Builds corrected `GitIgnore` / `GitRepos` objects for the fixable findings |
| `write()` | Writes `.gitrepos` then `.gitignore`, each atomically |

The pair of writes is not atomic: a crash between them can leave the files
disagreeing. `check()` reports that on the next run, which is judged good
enough for this tool.

### Findings

Every class's `check()` returns findings (`finding.d`) instead of printing, so each command decides what
to print, its exit status, and whether `--fix` applies. Each finding has:

| Field | Meaning |
|---|---|
| `directory` | The nested repo it concerns; `""` for a whole-file problem |
| `message` | Human-readable description |
| `fixable` | Whether `--fix` can repair it |

New criteria (still TBD) are added as new checks producing findings, without
changing callers.

### Checks

**Each file on its own:** `ParentDirectory.check()` includes the findings of
`GitIgnore.check()` and `GitRepos.check()`.

**The two files agree** (no disk access; unit-testable on objects alone):

- A line in `before`/`after` whose directory is in `.gitrepos` (a nested
  pattern outside the block). Fixable: `--fix` moves it into the block.
- A block entry with no `.gitrepos` entry, and the reverse.

**The disk agrees with the files** (needs real directories to test):

- The directory exists (#6, #7).
- The directory is a nested repo: `git -C <directory> rev-parse --show-toplevel`
  **succeeds** and prints the directory's **own** absolute path, compared
  after resolving symlinks on both sides
  ([git-rev-parse](https://git-scm.com/docs/git-rev-parse#Documentation/git-rev-parse.txt---show-toplevel)).
  Looking for a `.git/` directory is not used: in a linked worktree or
  submodule `.git` is a file ([gitrepository-layout](https://git-scm.com/docs/gitrepository-layout)).
  Observed with git 2.43:
  - through a symlinked path, git prints the symlink-**resolved** path;
  - for a plain folder with no repo above it, git fails with
    `fatal: not a git repository` and exit status 128;
  - for a plain folder inside a repo, git prints that repo's root.
- At least one remote's fetch url equals the entry's `url`, compared as exact
  text (`git@github.com:u/a.git` and `https://github.com/u/a.git` do not
  match; she decides).
- Further criteria: TBD.

### `--fix` and exit status

- **Without `--fix`:** report findings, change nothing.
- **With `--fix`:** build new objects with the fixable findings repaired,
  then write them.
- **Exit status:** non-zero when `check()` reports any finding, so scripts
  notice, as linters do.

## Open questions

- The other disk checks (TBD).
- How `add-nested` and `pull-nested` are rewritten on top of
  `ParentDirectory`, and whether `pull-nested` runs `check()` first.
