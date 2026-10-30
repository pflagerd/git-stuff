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
import nestedCommon : branchAfterClone, CommonOptions, currentBranch, ExitStatus,
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
ExitStatus run(string[] args, File output, File errors)
{
    CommonOptions commonOptions;
    PushOptions pushOptions;
    bool pushParent;
    const parsed = parseOptions(args, commonOptions, output, errors, usage,
        "origin-only", "Push only to the remote named origin.", &pushOptions.originOnly,
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

    ParentDirectory parentDirectory;
    if (!loadParent("push-nested", commonOptions.directory, parentDirectory, errors))
    {
        return ExitStatus.usage;
    }
    if (commonOptions.fix)
    {
        parentDirectory.fix();
        try
        {
            parentDirectory.write();
        }
        catch (Exception exception)
        {
            errors.writeln("push-nested: could not write the fixed files: ", exception.msg);
            return ExitStatus.findings;
        }
    }
    bool failed = printFindings(parentDirectory.check, errors) > 0;

    bool[string] seen;
    foreach (gitReposEntry; parentDirectory.gitRepos.gitReposEntries)
    {
        if (gitReposEntry.directory in seen)
        {
            continue; // a duplicate; check() has already reported it
        }
        seen[gitReposEntry.directory] = true;

        output.writeln("== ", gitReposEntry.directory);
        if (!pushNestedRepo(commonOptions.directory, gitReposEntry, pushOptions, output, errors))
        {
            failed = true;
        }
    }

    if (pushParent)
    {
        output.writeln("== parent ", commonOptions.directory);
        if (!pushParentDirectory(commonOptions.directory, pushOptions, output, errors))
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
 * `parentDirectory` is a path, not a ParentDirectory, on purpose.
 *
 * Returns: false if it was skipped or anything failed.
 */
bool pushNestedRepo(string parentDirectory, const GitReposEntry gitReposEntry,
    const PushOptions pushOptions, File output, File errors)
{
    import std.path : buildPath;

    immutable onDisk = buildPath(parentDirectory, gitReposEntry.directory[1 .. $ - 1]);
    void problem(string message)
    {
        output.flush();
        errors.writeln("push-nested: ", gitReposEntry.directory, ": ", message);
    }

    immutable notRepository = ParentDirectory.repositoryProblem(gitReposEntry.directory, onDisk);
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

    string expected = branchAfterClone(gitReposEntry.directory, gitReposEntry.url, gitReposEntry.branch,
        (string candidate) => remoteHasBranch(onDisk, candidate));
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

    return pushRepository(gitReposEntry.directory, onDisk, current, pushOptions, output, errors);
}

/**
 * Pushes the parent directory itself (--parent), which must be the top level
 * of its own repository and have a current branch.
 *
 * Returns: false if it was skipped or anything failed.
 */
bool pushParentDirectory(string parentDirectory, const PushOptions pushOptions, File output,
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
    return pushRepository(name, parentDirectory, current, pushOptions, output, errors);
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
bool pushRepository(string name, string onDisk, string branch, const PushOptions pushOptions,
    File output, File errors)
{
    import std.algorithm.searching : canFind;

    if (isDirty(onDisk))
    {
        output.writeln("note: ", name, " has uncommitted changes; only what's committed is pushed");
    }

    const all = remotes(onDisk);
    const targets = pushOptions.originOnly ? (all.canFind("origin") ? ["origin"] : []) : all;
    if (targets.length == 0)
    {
        output.flush();
        errors.writeln("push-nested: ", name, ": ",
            pushOptions.originOnly ? "no remote named origin" : "no remotes", "; skipped");
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

    const result = execute(["git", "-C", repository, "remote"]);
    return result.status == 0 ? result.output.strip.lineSplitter.array : [];
}

/// Whether the current branch has an upstream configured.
bool hasUpstream(string repository)
{
    import std.process : execute;

    const result = execute(["git", "-C", repository, "rev-parse", "--abbrev-ref",
        "--symbolic-full-name", "@{upstream}"]);
    return result.status == 0;
}

/// Whether the working tree or index has uncommitted changes (untracked
/// files included).
bool isDirty(string repository)
{
    import std.process : execute;
    import std.string : strip;

    const result = execute(["git", "-C", repository, "status", "--porcelain"]);
    return result.status == 0 && result.output.strip.length > 0;
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
    import nestedCommon : captured;
    import textFile : testDirectory;
    static import nestedCommon;

    /// Runs git, failing the test if it fails.
    private void sh(string[] args...)
    {
        nestedCommon.git(args);
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
        const result = execute(["git", "-C", repository, "rev-parse", "--verify", "--quiet",
            "refs/heads/" ~ branch]);
        return result.status == 0 ? result.output.strip : "";
    }

    /// The upstream of the current branch of `repository` ("" if none).
    private string upstream(string repository)
    {
        const result = execute(["git", "-C", repository, "rev-parse", "--abbrev-ref",
            "--symbolic-full-name", "@{upstream}"]);
        return result.status == 0 ? result.output.strip : "";
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

    /// The paths setUp() makes, by role.
    private struct PushSetUp
    {
        string parent; /// the parent directory
        string alpha;  /// the nested repo /alpha/, a clone of origin
        string origin; /// a bare repository, alpha's origin
        string mirror; /// a bare copy of origin, alpha's second remote
    }

    /// A parent directory with nested repo /alpha/ cloned from a fresh `origin`
    /// and given a second remote, `mirror`, holding the same history; both
    /// files list it.
    private PushSetUp setUp(string scratch)
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
        auto parentDirectory = new ParentDirectory(parent);
        parentDirectory.fix();
        parentDirectory.write();
        // Named fields, so they can't be swapped by position.
        PushSetUp pushSetUp = {parent: parent, alpha: alpha, origin: origin, mirror: mirror};
        return pushSetUp;
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

    const pushSetUp = setUp(scratch);
    commit(pushSetUp.alpha);
    string[2] text;
    assert(pushNested(scratch, pushSetUp.parent, [], text) == 0, text[1]);
    assert(tip(pushSetUp.origin, "main") == tip(pushSetUp.alpha, "main"));
    assert(tip(pushSetUp.mirror, "main") == tip(pushSetUp.alpha, "main"));
}

/// --origin-only leaves the other remotes alone.
unittest
{
    immutable scratch = testDirectory("pushNested-origin-only");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    const pushSetUp = setUp(scratch);
    immutable mirrorBefore = tip(pushSetUp.mirror, "main");
    commit(pushSetUp.alpha);
    string[2] text;
    assert(pushNested(scratch, pushSetUp.parent, ["--origin-only"], text) == 0, text[1]);
    assert(tip(pushSetUp.origin, "main") == tip(pushSetUp.alpha, "main"));
    assert(tip(pushSetUp.mirror, "main") == mirrorBefore);
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

    const pushSetUp = setUp(scratch);
    // A remote that sorts after origin: if -u went to every remote, the last
    // push (zeta) would win and the upstream would be zeta/feature.
    sh("-C", pushSetUp.alpha, "remote", "add", "zeta", pushSetUp.mirror);
    // A new branch has no upstream. (.gitrepos says main, so record this one.)
    sh("-C", pushSetUp.alpha, "checkout", "-q", "-b", "feature");
    commit(pushSetUp.alpha);
    buildPath(pushSetUp.parent, ".gitrepos").write("/alpha/ " ~ pushSetUp.origin ~ " feature\n");
    assert(upstream(pushSetUp.alpha) == "");

    string[2] text;
    assert(pushNested(scratch, pushSetUp.parent, [], text) == 0, text[1]);
    assert(upstream(pushSetUp.alpha) == "origin/feature");
    assert(tip(pushSetUp.origin, "feature") == tip(pushSetUp.alpha, "feature"));
    assert(tip(pushSetUp.mirror, "feature") == tip(pushSetUp.alpha, "feature"));

    // Point the upstream at the mirror instead: a push keeps it there.
    sh("-C", pushSetUp.alpha, "branch", "-q", "--set-upstream-to=mirror/feature");
    commit(pushSetUp.alpha);
    assert(pushNested(scratch, pushSetUp.parent, [], text) == 0, text[1]);
    assert(upstream(pushSetUp.alpha) == "mirror/feature");
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
    auto parentDirectory = new ParentDirectory(parent);
    parentDirectory.fix();
    parentDirectory.write();
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

    const pushSetUp = setUp(scratch);
    sh("-C", pushSetUp.alpha, "checkout", "-q", "-b", "feature");
    commit(pushSetUp.alpha);
    string[2] text;
    assert(pushNested(scratch, pushSetUp.parent, [], text) == 1);
    assert(text[1].canFind("on branch 'feature', but .gitrepos means 'main'; skipped"));
    assert(text[1].canFind("add-nested --branch"));
    assert(tip(pushSetUp.origin, "feature") == "" && tip(pushSetUp.mirror, "feature") == "");
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

    const pushSetUp = setUp(scratch);
    commit(pushSetUp.alpha);
    buildPath(pushSetUp.alpha, "unsaved.txt").write("not committed\n");
    string[2] text;
    assert(pushNested(scratch, pushSetUp.parent, [], text) == 0, text[1]);
    assert(text[0].canFind("note: /alpha/ has uncommitted changes"));
    assert(tip(pushSetUp.origin, "main") == tip(pushSetUp.alpha, "main"));
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

    const pushSetUp = setUp(scratch);
    // Someone else pushes to origin.
    immutable other = buildPath(scratch, "other");
    sh("clone", "-q", pushSetUp.origin, other);
    commit(other, "theirs");
    sh("-C", other, "push", "-q", "origin", "main");
    immutable theirs = tip(pushSetUp.origin, "main");

    commit(pushSetUp.alpha, "mine");
    string[2] text;
    assert(pushNested(scratch, pushSetUp.parent, [], text) == 1);
    assert(text[1].canFind("/alpha/: push to origin failed"));
    assert(tip(pushSetUp.origin, "main") == theirs);               // not overwritten
    assert(tip(pushSetUp.mirror, "main") == tip(pushSetUp.alpha, "main"));    // the mirror still got it
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

    const pushSetUp = setUp(scratch);
    string[2] text;

    sh("-C", pushSetUp.alpha, "checkout", "-q", "--detach");
    assert(pushNested(scratch, pushSetUp.parent, [], text) == 1);
    assert(text[1].canFind("no current branch (detached HEAD); skipped"));
    sh("-C", pushSetUp.alpha, "checkout", "-q", "main");

    sh("-C", pushSetUp.alpha, "remote", "rename", "origin", "upstream-copy");
    assert(pushNested(scratch, pushSetUp.parent, ["--origin-only"], text) == 1);
    assert(text[1].canFind("no remote named origin; skipped"));
    commit(pushSetUp.alpha);
    assert(pushNested(scratch, pushSetUp.parent, [], text) == 0, text[1]);   // its other remotes
    // git remote rename carried the upstream along; with no origin nothing resets it.
    assert(upstream(pushSetUp.alpha) == "upstream-copy/main");

    rmdirRecurse(pushSetUp.alpha);
    buildPath(pushSetUp.alpha).mkdirRecurse;
    assert(pushNested(scratch, pushSetUp.parent, [], text) == 1);
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

    const pushSetUp = setUp(scratch);
    string[2] text;
    assert(pushNested(scratch, pushSetUp.parent, ["--parent"], text) == 1);
    assert(text[1].canFind("the parent directory is not a git repository"));

    immutable parentRemote = bare(scratch, "parent-remote");
    sh("-C", pushSetUp.parent, "init", "-q", "-b", "main");
    sh("-C", pushSetUp.parent, "remote", "add", "origin", parentRemote);
    sh("-C", pushSetUp.parent, "add", ".gitrepos", ".gitignore");
    sh("-C", pushSetUp.parent, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "parent");
    sh("-C", pushSetUp.parent, "fetch", "-q", "origin");
    sh("-C", pushSetUp.parent, "reset", "-q", "--soft", "origin/main");
    commit(pushSetUp.parent, "parent work");

    assert(pushNested(scratch, pushSetUp.parent, ["--parent"], text) == 0, text[1]);
    assert(tip(parentRemote, "main") == tip(pushSetUp.parent, "main"));
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
