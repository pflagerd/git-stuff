# push-nested (proposal)

Status: **proposal, awaiting decisions.** Issue:
[#19](https://github.com/pflagerd/git-stuff/issues/19). Builds on
`docs/nested-commands-proposal.md`: same conventions as the other commands
(`run()` tested in-process against local repositories, exit statuses 0/1/2,
`-C` and `--fix`, a `== /dir/` header per repo, git run with an argument list
and its terminal, one repo's failure doesn't stop the others).

## What exists today

`bin/push` pushes the current repository to **every remote that has a push
url** (`git push <remote>` for each line of `git remote -v` ending in
`(push)`). `add_origin_host_remote.py` adds a second remote named after the
origin's host. Together they suggest repos are kept on more than one remote
and pushed to all of them. Plain `git push <remote>` with git's default
`push.default=simple` pushes the current branch to its upstream and refuses
when there is none
([git-config: push.default](https://git-scm.com/docs/git-config#Documentation/git-config.txt-pushdefault)).

## Proposed behaviour

`push-nested [-C <directory>] [--fix] [--all-remotes]`

For each `.gitrepos` entry, in order, under a `== /dir/` header:

- **Missing, or not a nested repo** (`repositoryProblem`): warning; skipped.
- **Detached HEAD:** warning; skipped (there is no branch to push).
- **Otherwise:** push the current branch: `git push <remote> HEAD`, which
  pushes it to the branch of the same name on that remote, without needing
  or setting an upstream
  ([git-push](https://git-scm.com/docs/git-push#Documentation/git-push.txt-ltrefspecgt82308203)).
  Git's own message says when there was nothing to push ("Everything
  up-to-date").
- **Never force.** A rejected push (the remote has commits she doesn't) is
  reported and the repo left as it is; she pulls first.

Problems with the two files are reported first but don't stop the push, as
with `pull-nested`.

## Decisions

1. **Which remote(s)?**
   - (a) The remote whose url is the one in `.gitrepos` (usually `origin`),
     by default; `--all-remotes` pushes to every remote with a push url, as
     `bin/push` does. **(Recommended.)** `.gitrepos` stays the single source
     of truth by default, and the mirror habit is one option away.
   - (b) Every remote with a push url, always (like `bin/push`).
   - (c) Only the `.gitrepos` remote; no option.
2. **Which branch?** The current branch only, as `git push <remote> HEAD`
   (recommended). Alternatives: every local branch (`--all`), or the branch
   `.gitrepos` means even if she's on another (would push work she isn't
   looking at).
3. **On a different branch from the one `.gitrepos` means:** warn, and push
   the current branch anyway (recommended: pushing never changes her working
   tree, and refusing would surprise her); or skip the repo.
4. **Uncommitted changes:** warn that they won't be pushed, and push what is
   committed (recommended); or skip the repo.
5. **The parent directory itself:** not pushed; `push-nested` pushes only the
   nested repos (recommended: the parent may not even be a repository, and
   she pushes it as usual). Alternatively `--parent` to push it too.
6. **Upstream:** don't set one (`git push` without `-u`; recommended: it would
   change her repos' configuration as a side effect).
