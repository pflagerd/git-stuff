# Results instead of status strings (decision)

Status: **decided**; conversion in progress. Issue:
[#20](https://github.com/pflagerd/git-stuff/issues/20).

## The problem

Five functions reported failure by returning a message, with `""` (or, in
one case, `null`) meaning success:

| Function | Where |
|---|---|
| `directoryProblem` | `addNested.d` |
| `entryFor` | `addNested.d` (also passes on the others' messages) |
| `GitRepos.validate` | `gitRepos.d` (returned `null`, not `""`) |
| `cloneNested` | `nestedCommon.d` |
| `ParentDirectory.repositoryProblem` | `parentDirectory.d` |

What that cost:

- A caller that needed to know *which* failure had to work it out again.
  add-nested told a failed clone from a failed checkout by looking at the
  disk (`onDisk.exists`), though `cloneNested` knew the answer.
- `""` and `null` both meant success, and `entryFor` converted between
  them.
- Tests could only check the wording of a message, not what happened.
- "Empty means fine" was a convention the type didn't express.

The one real argument for strings: the messages carry details (the
directory, the url, git's own error output) that a bare enum can't.

## Options considered

- **A.** Keep strings, always `""`. Smallest change; fixes only the
  `null`/`""` mismatch.
- **B.** Return a bare enum. Loses the details, or needs a second `out`
  parameter for them.
- **C.** Return a small struct: an enum saying what happened, and the
  message. **Chosen.**
- **D.** Throw an exception per kind of failure. Kept for "can't go on at
  all" (an unreadable file); these failures are expected results that are
  reported and skipped in a loop, where `try`/`catch` at every call would
  be noise.

## The decision

A function that can fail in ways a caller may need to tell apart returns a
result struct:

```d
/// What cloneNested did.
enum CloneOutcome { cloned, cloneFailed, checkoutFailed }

/// cloneNested's result: what happened, and a message for her to read.
@mustuse struct CloneResult
{
    CloneOutcome outcome;
    string message; /// "" when outcome is cloned
}
```

- **One enum per function**, listing only what that function can produce,
  so a `final switch` on it has no impossible cases.
- **`@mustuse`** ([core.attribute](https://dlang.org/phobos/core_attribute.html#.mustuse))
  makes ignoring the result a compile error. Checked on LDC 1.36.0:
  "ignored value of `@mustuse` type ...".
- **`final switch`** ([D spec](https://dlang.org/spec/statement.html#final-switch-statement))
  where a caller acts on the outcome: leaving out a member is a compile
  error (also checked on LDC 1.36.0).
- Callers act on the enum and print the message. Tests check the enum,
  and the message only where its wording is the point.
- No `""` or `null` string as a status in new code.

Functions that return `""` meaning "no value" (`currentBranch`,
`remoteDefaultBranch`, `originUrl`, `readIfExists`, ...) are a different
pattern and a separate issue (`Nullable`).

## Order of conversion

One function per commit, each with `make test` passing:

1. `cloneNested`: the one where the string lost information.
2. `ParentDirectory.repositoryProblem`
3. `GitRepos.validate`
4. `directoryProblem`
5. `entryFor`, which combines the others.
