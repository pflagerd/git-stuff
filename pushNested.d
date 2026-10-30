/**
 * push-nested: pushes the current branch of each nested repo in .gitrepos
 * to its remotes (all of them, or only origin), and with --parent the
 * parent directory too.
 *
 * Design: docs/push-nested-proposal.md
 */
module pushNested;

import std.stdio : File;

import gitRepos : GitReposEntry;
import nestedCommand : branchAfterClone, CommonOptions, currentBranch, ExitStatus,
    loadParent, parseOptions, printFindings, remoteDefaultBranch, remoteHasBranch, runGit;
import parentDirectory : ParentDirectory;

enum usage = "Usage: push-nested [-C <directory>] [--fix] [--origin-only] [--parent]

Pushes the current branch of each nested repo in .gitrepos to every remote
it has (only origin with --origin-only), setting the upstream to origin if
the branch has none. Never forces. A repo on a different branch from the
one .gitrepos means is skipped. With --parent, also pushes the parent
directory. Exit status: 0 done, 1 a repo was skipped or failed or problems
remain, 2 bad usage or a file that can't be read.
";

/// What a push run was asked to do.
struct PushOptions
{
    bool originOnly; /// --origin-only: push only to the remote named origin
}

/**
 * Does all of push-nested's work; main() only calls this, so tests can run
 * it in-process with `output` and `errors` captured.
 *
 * Returns: the exit status.
 */
int run(string[] args, File output, File errors)
{
    CommonOptions common;
    PushOptions push;
    bool pushParent;
    const parsed = parseOptions(args, common, output, errors, usage,
        "origin-only", "Push only to the remote named origin.", &push.originOnly,
        "parent", "Also push the parent directory itself, after the nested repos.", &pushParent);
    if (!parsed.proceed)
    {
        return parsed.exitStatus;
    }
    if (args.length > 1)
    {
        errors.writeln("push-nested: unexpected argument '", args[1], "'");
        return ExitStatus.usage;
    }

    ParentDirectory parent;
    if (!loadParent("push-nested", common.directory, parent, errors))
    {
        return ExitStatus.usage;
    }
    if (common.fix)
    {
        parent.fix();
        try
        {
            parent.write();
        }
        catch (Exception e)
        {
            errors.writeln("push-nested: could not write the fixed files: ", e.msg);
            return ExitStatus.findings;
        }
    }
    bool failed = printFindings(parent.check, errors) > 0;

    bool[string] seen;
    foreach (entry; parent.gitRepos.entries)
    {
        if (entry.directory in seen)
        {
            continue; // a duplicate; check() has already reported it
        }
        seen[entry.directory] = true;

        output.writeln("== ", entry.directory);
        if (!pushNestedRepo(common.directory, entry, push, output, errors))
        {
            failed = true;
        }
    }

    if (pushParent)
    {
        output.writeln("== parent ", common.directory);
        if (!pushParentDirectory(common.directory, push, output, errors))
        {
            failed = true;
        }
    }

    return failed ? ExitStatus.findings : ExitStatus.ok;
}

/**
 * Pushes one nested repo, after checking it is a repo, has a current branch,
 * and is on the branch .gitrepos means (decision 3: otherwise skipped, and
 * the warning says what to do; nothing is switched).
 *
 * Returns: false if it was skipped or anything failed.
 */
bool pushNestedRepo(string parentDirectory, const GitReposEntry entry,
    const PushOptions push, File output, File errors)
{
    import std.path : buildPath;

    immutable onDisk = buildPath(parentDirectory, entry.directory[1 .. $ - 1]);
    void problem(string message)
    {
        output.flush();
        errors.writeln("push-nested: ", entry.directory, ": ", message);
    }

    immutable notRepository = ParentDirectory.repositoryProblem(entry.directory, onDisk);
    if (notRepository.length)
    {
        problem(notRepository ~ "; skipped");
        return false;
    }

    immutable current = currentBranch(onDisk);
    if (current.length == 0)
    {
        problem("no current branch (detached HEAD); skipped");
        return false;
    }

    string expected = branchAfterClone(entry.directory, entry.url, entry.branch,
        (string b) => remoteHasBranch(onDisk, b));
    if (expected.length == 0)
    {
        expected = remoteDefaultBranch(onDisk); // "" if unknown: nothing to compare
    }
    if (expected.length && current != expected)
    {
        problem("on branch '" ~ current ~ "', but .gitrepos means '" ~ expected
            ~ "'; skipped (switch to '" ~ expected ~ "', or record '" ~ current
            ~ "' in .gitrepos with add-nested --branch, then run push-nested again)");
        return false;
    }

    return pushRepository(entry.directory, onDisk, current, push, output, errors);
}

/**
 * Pushes the parent directory itself (--parent), which must be the top level
 * of its own repository and have a current branch.
 *
 * Returns: false if it was skipped or anything failed.
 */
bool pushParentDirectory(string parentDirectory, const PushOptions push, File output,
    File errors)
{
    immutable name = "the parent directory";
    immutable notRepository = ParentDirectory.repositoryProblem(name, parentDirectory);
    if (notRepository.length)
    {
        output.flush();
        errors.writeln("push-nested: ", notRepository, "; --parent skipped");
        return false;
    }
    immutable current = currentBranch(parentDirectory);
    if (current.length == 0)
    {
        output.flush();
        errors.writeln("push-nested: ", name, " has no current branch (detached HEAD); skipped");
        return false;
    }
    return pushRepository(name, parentDirectory, current, push, output, errors);
}

/**
 * Pushes `branch` of the repository at `onDisk` to every remote (only origin
 * with --origin-only). On the push to origin, if the branch has no upstream
 * yet, uses `git push -u origin <branch>` so origin/<branch> becomes its
 * upstream (decision 6). Never forces. Uncommitted changes get a note: they
 * aren't pushed (decision 4).
 *
 * Returns: false if a push failed or there was nothing to push to.
 */
bool pushRepository(string name, string onDisk, string branch, const PushOptions push,
    File output, File errors)
{
    import std.algorithm.searching : canFind;

    if (isDirty(onDisk))
    {
        output.writeln("note: ", name, " has uncommitted changes; only what's committed is pushed");
    }

    const all = remotes(onDisk);
    const targets = push.originOnly ? (all.canFind("origin") ? ["origin"] : []) : all;
    if (targets.length == 0)
    {
        output.flush();
        errors.writeln("push-nested: ", name, ": ",
            push.originOnly ? "no remote named origin" : "no remotes", "; skipped");
        return false;
    }

    immutable setUpstream = !hasUpstream(onDisk);
    bool ok = true;
    foreach (remote; targets)
    {
        string[] command = ["-C", onDisk, "push"];
        if (remote == "origin" && setUpstream)
        {
            command ~= "-u";
        }
        command ~= [remote, branch];
        if (!runGit(command, output, errors))
        {
            output.flush();
            errors.writeln("push-nested: ", name, ": push to ", remote, " failed");
            ok = false;
        }
    }
    return ok;
}

/// The repository's remote names, in the order `git remote` lists them.
string[] remotes(string repository)
{
    import std.array : array;
    import std.process : execute;
    import std.string : lineSplitter, strip;

    const r = execute(["git", "-C", repository, "remote"]);
    return r.status == 0 ? r.output.strip.lineSplitter.array : [];
}

/// Whether the current branch has an upstream configured.
bool hasUpstream(string repository)
{
    import std.process : execute;

    const r = execute(["git", "-C", repository, "rev-parse", "--abbrev-ref",
        "--symbolic-full-name", "@{upstream}"]);
    return r.status == 0;
}

/// Whether the working tree or index has uncommitted changes (untracked
/// files included).
bool isDirty(string repository)
{
    import std.process : execute;
    import std.string : strip;

    const r = execute(["git", "-C", repository, "status", "--porcelain"]);
    return r.status == 0 && r.output.strip.length > 0;
}

version (unittest)
{
}
else
{
    int main(string[] args)
    {
        import std.stdio : stderr, stdout;

        return run(args, stdout, stderr);
    }
}

// --- tests -----------------------------------------------------------------------

version (unittest)
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.string : strip;
    import nestedCommand : captured;
    import textFile : testDirectory;
    static import nestedCommand;

    /// Runs git, failing the test if it fails.
    private void sh(string[] args...)
    {
        nestedCommand.git(args);
    }

    /// Runs push-nested on `parent`; returns the exit status, and what went
    /// to output and errors.
    private int pushNested(string scratch, string parent, string[] extra, out string[2] text)
    {
        int status;
        text = captured(scratch, (File output, File errors) {
            status = run(["push-nested", "-C", parent] ~ extra, output, errors);
        });
        return status;
    }

    /// Commits an empty change in `repository`.
    private void commit(string repository, string message = "work")
    {
        sh("-C", repository, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
            "--allow-empty", "-m", message);
    }

    /// The commit `branch` is at in `repository` ("" if it has no such branch).
    private string tip(string repository, string branch)
    {
        const r = execute(["git", "-C", repository, "rev-parse", "--verify", "--quiet",
            "refs/heads/" ~ branch]);
        return r.status == 0 ? r.output.strip : "";
    }

    /// The upstream of the current branch of `repository` ("" if none).
    private string upstream(string repository)
    {
        const r = execute(["git", "-C", repository, "rev-parse", "--abbrev-ref",
            "--symbolic-full-name", "@{upstream}"]);
        return r.status == 0 ? r.output.strip : "";
    }

    /// A bare repository `<name>.git` in `scratch` with one commit on `main`.
    private string bare(string scratch, string name)
    {
        immutable path = buildPath(scratch, name ~ ".git");
        immutable seed = buildPath(scratch, name ~ "-seed");
        sh("init", "-q", "--bare", "-b", "main", path);
        sh("init", "-q", "-b", "main", seed);
        commit(seed, "init");
        sh("-C", seed, "push", "-q", path, "main");
        return path;
    }

    /// A parent directory with nested repo /alpha/ cloned from a fresh `origin`
    /// and given a second remote, `mirror`, holding the same history; both
    /// files list it. Returns [parent, alpha, origin, mirror].
    private string[4] setUp(string scratch)
    {
        import parentDirectory : ParentDirectory;

        immutable origin = bare(scratch, "origin");
        immutable mirror = buildPath(scratch, "mirror.git");
        sh("clone", "-q", "--bare", origin, mirror);
        immutable parent = buildPath(scratch, "parent");
        immutable alpha = buildPath(parent, "alpha");
        sh("clone", "-q", origin, alpha);
        sh("-C", alpha, "remote", "add", "mirror", mirror);
        parent.mkdirRecurse;
        buildPath(parent, ".gitrepos").write("/alpha/ " ~ origin ~ "\n");
        auto p = new ParentDirectory(parent);
        p.fix();
        p.write();
        return [parent, alpha, origin, mirror];
    }
}

/// By default the current branch goes to every remote.
unittest
{
    immutable scratch = testDirectory("pushNested-all");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    const s = setUp(scratch);
    commit(s[1]);
    string[2] text;
    assert(pushNested(scratch, s[0], [], text) == 0, text[1]);
    assert(tip(s[2], "main") == tip(s[1], "main"));
    assert(tip(s[3], "main") == tip(s[1], "main"));
}

/// --origin-only leaves the other remotes alone.
unittest
{
    immutable scratch = testDirectory("pushNested-origin-only");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    const s = setUp(scratch);
    immutable mirrorBefore = tip(s[3], "main");
    commit(s[1]);
    string[2] text;
    assert(pushNested(scratch, s[0], ["--origin-only"], text) == 0, text[1]);
    assert(tip(s[2], "main") == tip(s[1], "main"));
    assert(tip(s[3], "main") == mirrorBefore);
}

/// A branch with no upstream gets origin/<branch>; an existing upstream, even
/// to another remote, is left alone.
unittest
{
    immutable scratch = testDirectory("pushNested-upstream");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    const s = setUp(scratch);
    // A remote that sorts after origin: if -u went to every remote, the last
    // push (zeta) would win and the upstream would be zeta/feature.
    sh("-C", s[1], "remote", "add", "zeta", s[3]);
    // A new branch has no upstream. (.gitrepos says main, so record this one.)
    sh("-C", s[1], "checkout", "-q", "-b", "feature");
    commit(s[1]);
    buildPath(s[0], ".gitrepos").write("/alpha/ " ~ s[2] ~ " feature\n");
    assert(upstream(s[1]) == "");

    string[2] text;
    assert(pushNested(scratch, s[0], [], text) == 0, text[1]);
    assert(upstream(s[1]) == "origin/feature");
    assert(tip(s[2], "feature") == tip(s[1], "feature"));
    assert(tip(s[3], "feature") == tip(s[1], "feature"));

    // Point the upstream at the mirror instead: a push keeps it there.
    sh("-C", s[1], "branch", "-q", "--set-upstream-to=mirror/feature");
    commit(s[1]);
    assert(pushNested(scratch, s[0], [], text) == 0, text[1]);
    assert(upstream(s[1]) == "mirror/feature");
}

/// The usual no-upstream case: master in a repo made with git init and git
/// remote add (git clone would have set an upstream). The upstream becomes
/// origin/master, the branch she's on.
unittest
{
    import parentDirectory : ParentDirectory;

    immutable scratch = testDirectory("pushNested-master-upstream");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = buildPath(scratch, "beta.git");
    sh("init", "-q", "--bare", "-b", "master", remote);
    immutable parent = buildPath(scratch, "parent");
    immutable beta = buildPath(parent, "beta");
    sh("init", "-q", "-b", "master", beta);
    sh("-C", beta, "remote", "add", "origin", remote);
    commit(beta);
    buildPath(parent, ".gitrepos").write("/beta/ " ~ remote ~ "\n");
    auto p = new ParentDirectory(parent);
    p.fix();
    p.write();
    assert(upstream(beta) == "");

    string[2] text;
    assert(pushNested(scratch, parent, [], text) == 0, text[1]);
    assert(upstream(beta) == "origin/master");
    assert(tip(remote, "master") == tip(beta, "master"));
}

/// On a different branch from the one .gitrepos means: skipped, nothing pushed,
/// and the warning says what to do.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pushNested-other-branch");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    const s = setUp(scratch);
    sh("-C", s[1], "checkout", "-q", "-b", "feature");
    commit(s[1]);
    string[2] text;
    assert(pushNested(scratch, s[0], [], text) == 1);
    assert(text[1].canFind("on branch 'feature', but .gitrepos means 'main'; skipped"));
    assert(text[1].canFind("add-nested --branch"));
    assert(tip(s[2], "feature") == "" && tip(s[3], "feature") == "");
}

/// Uncommitted changes: a note, the committed work is pushed, exit 0.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pushNested-dirty");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    const s = setUp(scratch);
    commit(s[1]);
    buildPath(s[1], "unsaved.txt").write("not committed\n");
    string[2] text;
    assert(pushNested(scratch, s[0], [], text) == 0, text[1]);
    assert(text[0].canFind("note: /alpha/ has uncommitted changes"));
    assert(tip(s[2], "main") == tip(s[1], "main"));
}

/// A rejected push (the remote has moved on) fails, never forces, and the
/// other remotes are still pushed.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pushNested-rejected");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    const s = setUp(scratch);
    // Someone else pushes to origin.
    immutable other = buildPath(scratch, "other");
    sh("clone", "-q", s[2], other);
    commit(other, "theirs");
    sh("-C", other, "push", "-q", "origin", "main");
    immutable theirs = tip(s[2], "main");

    commit(s[1], "mine");
    string[2] text;
    assert(pushNested(scratch, s[0], [], text) == 1);
    assert(text[1].canFind("/alpha/: push to origin failed"));
    assert(tip(s[2], "main") == theirs);               // not overwritten
    assert(tip(s[3], "main") == tip(s[1], "main"));    // the mirror still got it
}

/// Not a repository, detached HEAD, and --origin-only without origin: skipped.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pushNested-skips");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    const s = setUp(scratch);
    string[2] text;

    sh("-C", s[1], "checkout", "-q", "--detach");
    assert(pushNested(scratch, s[0], [], text) == 1);
    assert(text[1].canFind("no current branch (detached HEAD); skipped"));
    sh("-C", s[1], "checkout", "-q", "main");

    sh("-C", s[1], "remote", "rename", "origin", "upstream-copy");
    assert(pushNested(scratch, s[0], ["--origin-only"], text) == 1);
    assert(text[1].canFind("no remote named origin; skipped"));
    commit(s[1]);
    assert(pushNested(scratch, s[0], [], text) == 0, text[1]);   // its other remotes
    // git remote rename carried the upstream along; with no origin nothing resets it.
    assert(upstream(s[1]) == "upstream-copy/main");

    rmdirRecurse(s[1]);
    buildPath(s[1]).mkdirRecurse;
    assert(pushNested(scratch, s[0], [], text) == 1);
    assert(text[1].canFind("is not a git repository") && text[1].canFind("skipped"));
}

/// --parent pushes the parent too, after the nested repos; a parent that isn't
/// a repository is reported.
unittest
{
    import std.algorithm.searching : canFind;
    import std.string : indexOf;

    immutable scratch = testDirectory("pushNested-parent");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    const s = setUp(scratch);
    string[2] text;
    assert(pushNested(scratch, s[0], ["--parent"], text) == 1);
    assert(text[1].canFind("the parent directory is not a git repository"));

    immutable parentRemote = bare(scratch, "parent-remote");
    sh("-C", s[0], "init", "-q", "-b", "main");
    sh("-C", s[0], "remote", "add", "origin", parentRemote);
    sh("-C", s[0], "add", ".gitrepos", ".gitignore");
    sh("-C", s[0], "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "parent");
    sh("-C", s[0], "fetch", "-q", "origin");
    sh("-C", s[0], "reset", "-q", "--soft", "origin/main");
    commit(s[0], "parent work");

    assert(pushNested(scratch, s[0], ["--parent"], text) == 0, text[1]);
    assert(tip(parentRemote, "main") == tip(s[0], "main"));
    assert(text[0].indexOf("== /alpha/") < text[0].indexOf("== parent "));
}

/// Usage: a positional argument, an unknown option, --help, a malformed file.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pushNested-usage");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    string[2] text;
    assert(pushNested(scratch, scratch, ["alpha"], text) == 2);
    assert(text[1].canFind("unexpected argument 'alpha'"));
    assert(pushNested(scratch, scratch, ["--nonsense"], text) == 2);
    assert(pushNested(scratch, scratch, ["--help"], text) == 0);
    assert(text[0].canFind("Usage: push-nested"));
    buildPath(scratch, ".gitrepos").write("/alpha/\n");
    assert(pushNested(scratch, scratch, [], text) == 2);
}
