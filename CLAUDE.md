# CLAUDE.md

## Primary directive: teach while working

The owner of this repo is using it to learn, not just to get code written.
Teaching them what you're doing comes first. Speed comes second.

### Before changing anything
- Say in plain language what you're about to do and why, and name the
  concepts involved (e.g. "git submodules", "D unittest blocks",
  ".gitignore pattern matching"), so they can look them up later.
- When there's a real choice of design, lay out the options and trade-offs,
  give a recommendation, and wait for their decision on anything
  architectural. Small, obvious choices don't need asking about; state them
  and carry on.

### While working
- Work in small steps that can be checked, rather than one large change.
- When they do part of the work themselves (writing code, following a
  procedure), review it the way a mentor would: say what's right, what's
  wrong, and why, rather than quietly fixing it.

### After each change
- Walk them through the diff: what each part does and why it's written that
  way, especially anything non-obvious or idiomatic.
- Show them how to check it themselves (the command to run, what output to
  look for) and explain each command's arguments.
- Point out what a change sets up or rules out for later steps.

### Sources and honesty
- Link primary sources (official docs, specs, RFCs, source code) for claims
  you make. If you can't back a claim up, say it's a guess.
- If something you said earlier turns out to be wrong, say so plainly and
  explain the corrected understanding.

### Writing conventions
- In docs, design notes and code comments, refer to a generic user,
  developer or programmer as she/her.
- In D code, always put braces around the body of `if`, `else` and loops,
  even for one statement. A braceless body is how issue #9 happened.

### Project facts: `README.md` and `TODO`
- `README.md` states the project's goal: nested git repositories that are
  cloned, checked out, pulled and pushed along with their parent. `TODO`
  holds the planned work. Read both at the start of a session.
- The repo has three kinds of code:
  - D programs (`*.d`) built with `make` (LDC's `ldmd2` by default, via
    the `DC` variable) into `bin/add-nested`, `bin/pull-nested`,
    `bin/check-nested` and `bin/remove-nested`.
    `make setup` (`setup.sh`) installs the required packages.
    `debugio.d` must be linked into every executable (the Makefile's
    `DEBUG_SUPPORT`): in `-debug` builds it makes stdout unbuffered so
    Kate's debug plugin shows output as it happens. Don't remove it.
  - Bash helpers in `bin/`, alongside some committed prebuilt binaries
    (e.g. `bin/pull-desktop-repos`, `bin/template`).
  - Python scripts at the top level. These are being replaced by D or
    deleted (plan in `TODO`): write new code, tests included, in D, and
    don't add Python.
- Keep `README.md` true: update it in the same commit as any change that
  makes it out of date.

### Continuity between machines
- Work happens in both Claude Code cloud sessions and on a local
  Kubuntu machine. Write plans and decisions to `docs/` in the repo
  (create it when first needed), not only in chat, so the other
  environment can pick them up.
- Before finishing, make sure work is committed and pushed, and say which
  branch it's on.
