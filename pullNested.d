/**
 * pull-nested: clones the nested repos .gitrepos lists that are missing,
 * and fast-forwards the ones that exist.
 *
 * Design: docs/nested-commands-proposal.md (decision 6)
 */
module pullNested;

import std.stdio : File;

import gitRepos : GitReposEntry;
import nestedCommand : branchAfterClone, CommonOptions, currentBranch, ExitStatus,
    lastComponent, loadParent, namesDiffer, parseOptions, printFindings,
    remoteDefaultBranch, remoteHasBranch;
import parentDirectory : ParentDirectory;

enum usage = "Usage: pull-nested [-C <directory>] [--fix]

For each nested repo in .gitrepos: clones it if it is missing and checks
out its branch; otherwise runs git pull --ff-only, which only ever moves a
branch forward. An existing repo is never switched to another branch.
Exit status: 0 done, 1 a repo failed or problems remain, 2 bad usage or a
file that can't be read.
";

/**
 * Does all of pull-nested's work; main() only calls this, so tests can run
 * it in-process with `output` and `errors` captured. Git writes straight to
 * `output` and `errors`, so its messages appear as they happen.
 *
 * Returns: the exit status.
 */
int run(string[] args, File output, File errors)
{
    CommonOptions common;
    const parsed = parseOptions(args, common, output, errors, usage);
    if (!parsed.proceed)
    {
        return parsed.exitStatus;
    }
    if (args.length > 1)
    {
        errors.writeln("pull-nested: unexpected argument '", args[1], "'");
        return ExitStatus.usage;
    }

    ParentDirectory parent;
    if (!loadParent("pull-nested", common.directory, parent, errors))
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
            errors.writeln("pull-nested: could not write the fixed files: ", e.msg);
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
        if (!pullOne(common.directory, entry, output, errors))
        {
            failed = true;
        }
    }

    return failed ? ExitStatus.findings : ExitStatus.ok;
}

/**
 * Clones or fast-forwards one nested repo. Problems are reported on `errors`
 * prefixed "pull-nested: <directory>: ".
 *
 * Returns: false if anything went wrong or needs her attention.
 */
bool pullOne(string parentDirectory, const GitReposEntry entry, File output, File errors)
{
    import std.file : exists;
    import std.path : buildPath;

    immutable onDisk = buildPath(parentDirectory, entry.directory[1 .. $ - 1]);
    void problem(string message)
    {
        output.flush();
        errors.writeln("pull-nested: ", entry.directory, ": ", message);
    }

    if (!onDisk.exists)
    {
        if (!git(["clone", entry.url, onDisk], output, errors))
        {
            problem("git clone failed");
            return false;
        }
        immutable target = branchAfterClone(entry.directory, entry.url, entry.branch,
            (string b) => remoteHasBranch(onDisk, b));
        if (target.length && currentBranch(onDisk) != target)
        {
            if (!git(["-C", onDisk, "checkout", "--quiet", target], output, errors))
            {
                problem("cloned, but could not check out branch '" ~ target ~ "'");
                return false;
            }
        }
        else if (target.length == 0 && entry.branch.length == 0
            && namesDiffer(entry.directory, entry.url))
        {
            output.writeln("no branch \"", lastComponent(entry.directory),
                "\" on the remote; staying on ", currentBranch(onDisk));
        }
        return true;
    }

    immutable notRepository = ParentDirectory.repositoryProblem(entry.directory, onDisk);
    if (notRepository.length)
    {
        problem(notRepository ~ "; skipped");
        return false;
    }

    // Never switch branches in an existing repo (decision 6 part 2): she may
    // be working there. Just say so if it isn't where .gitrepos points.
    string expected = branchAfterClone(entry.directory, entry.url, entry.branch,
        (string b) => remoteHasBranch(onDisk, b));
    if (expected.length == 0)
    {
        expected = remoteDefaultBranch(onDisk); // "" if unknown: nothing to compare
    }
    immutable current = currentBranch(onDisk);
    bool ok = true;
    if (expected.length && current != expected)
    {
        problem("on " ~ (current.length ? "branch '" ~ current ~ "'" : "a detached HEAD")
            ~ ", but .gitrepos means '" ~ expected ~ "'; not switching");
        ok = false;
    }

    if (!git(["-C", onDisk, "pull", "--ff-only"], output, errors))
    {
        problem("git pull --ff-only failed; nothing was changed in this repo");
        return false;
    }
    return ok;
}

/**
 * Runs git with `args`, its output going straight to `output` and `errors`
 * (so progress and messages appear as they happen), and its input from the
 * terminal (so ssh can still ask for a passphrase). Never through a shell.
 *
 * Returns: whether git succeeded.
 */
bool git(string[] args, File output, File errors)
{
    import std.process : Config, spawnProcess, wait;
    import std.stdio : stdin;

    output.flush(); // so our own lines come before git's
    errors.flush();
    // spawnProcess closes, in this process, any File it is given that isn't
    // our own stdout/stderr (e.g. the files tests capture into), unless told
    // to retain it: https://dlang.org/phobos/std_process.html#.Config
    return wait(spawnProcess(["git"] ~ args, stdin, output, errors, null,
        Config.retainStdout | Config.retainStderr)) == 0;
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
    import gitRepos : escapeField;
    import nestedCommand : captured;
    import textFile : testDirectory;
    static import nestedCommand;

    /// Runs git, failing the test if it fails (nestedCommand's helper).
    private void sh(string[] args...)
    {
        nestedCommand.git(args);
    }

    /// Runs pull-nested on `parent`; returns the exit status, and what went
    /// to output and errors.
    private int pullNested(string scratch, string parent, string[] extra, out string[2] text)
    {
        int status;
        text = captured(scratch, (File output, File errors) {
            status = run(["pull-nested", "-C", parent] ~ extra, output, errors);
        });
        return status;
    }

    /// Commits an empty change in `repository` with message `message`.
    private void commit(string repository, string message)
    {
        sh("-C", repository, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
            "--allow-empty", "-m", message);
    }

    /// A bare remote `<name>.git` in `scratch` with `branches` (the first is
    /// its default) and one commit; returns its path.
    private string makeRemote(string scratch, string name, string[] branches...)
    {
        immutable remote = buildPath(scratch, name ~ ".git");
        immutable seed = buildPath(scratch, name ~ "-seed");
        sh("init", "-q", "--bare", "-b", branches[0], remote);
        sh("init", "-q", "-b", branches[0], seed);
        commit(seed, "init");
        foreach (b; branches)
        {
            sh("-C", seed, "push", "-q", remote, branches[0] ~ ":" ~ b);
        }
        return remote;
    }

    /// Adds a commit to `branch` of `remote` (through its seed clone).
    private void advance(string scratch, string name, string branch)
    {
        immutable seed = buildPath(scratch, name ~ "-seed");
        commit(seed, "more");
        sh("-C", seed, "push", "-q", buildPath(scratch, name ~ ".git"), "HEAD:" ~ branch);
    }

    /// The commit `repository`'s HEAD is at.
    private string head(string repository)
    {
        import std.process : execute;
        import std.string : strip;

        return execute(["git", "-C", repository, "rev-parse", "HEAD"]).output.strip;
    }

    /// Writes .gitrepos in `parent` (creating it) and, unless `alone`, a
    /// .gitignore whose block matches it, so the files start consistent.
    private void gitrepos(string parent, string text, bool alone = false)
    {
        parent.mkdirRecurse;
        buildPath(parent, ".gitrepos").write(text);
        if (!alone)
        {
            auto p = new ParentDirectory(parent);
            p.fix();
            p.write();
        }
    }
}

/// A missing repo is cloned, on its default branch.
unittest
{
    immutable scratch = testDirectory("pullNested-clone");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main", "dev");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "/alpha/ " ~ remote ~ "\n");

    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 0, text[1]);
    assert(currentBranch(buildPath(parent, "alpha")) == "main");
}

/// #2's example: blog/ from blog-bootstrap, listed branch bok-blog.
unittest
{
    immutable scratch = testDirectory("pullNested-issue-2");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "blog-bootstrap", "master", "bok-blog");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "blog/ " ~ remote ~ " bok-blog\n");

    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 0, text[1]);
    immutable blog = buildPath(parent, "blog");
    assert(blog.exists && !buildPath(parent, "blog-bootstrap").exists);
    assert(currentBranch(blog) == "bok-blog");
}

/// The directory-name rule: a branch named after the directory if the
/// remote has one, else the default with a note.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pullNested-directory-name");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable withBlog = makeRemote(scratch, "site", "master", "blog");
    immutable without = makeRemote(scratch, "other", "master");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "/blog/ " ~ withBlog ~ "\n/notes/ " ~ without ~ "\n");

    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 0, text[1]);
    assert(currentBranch(buildPath(parent, "blog")) == "blog");
    assert(currentBranch(buildPath(parent, "notes")) == "master");
    assert(text[0].canFind("no branch \"notes\" on the remote; staying on master"));
}

/// A name with a space works end to end (#3).
unittest
{
    immutable scratch = testDirectory("pullNested-space");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "my repo", "main");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "/My%20Repo/ " ~ escapeField(remote) ~ "\n");

    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 0, text[1]);
    assert(currentBranch(buildPath(parent, "My Repo")) == "main");
}

/// An existing repo that is behind is fast-forwarded.
unittest
{
    immutable scratch = testDirectory("pullNested-fast-forward");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "/alpha/ " ~ remote ~ "\n");
    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 0, text[1]);

    immutable alpha = buildPath(parent, "alpha");
    immutable before = head(alpha);
    advance(scratch, "alpha", "main");
    assert(pullNested(scratch, parent, [], text) == 0, text[1]);
    assert(head(alpha) != before && head(alpha) == head(buildPath(scratch, "alpha-seed")));
}

/// Diverged: --ff-only refuses, the repo is untouched, the others still pull.
/// The run sets pull.rebase=false (through git's GIT_CONFIG_* environment
/// variables), a setting under which plain `git pull` would merge; with no
/// pull.* settings git refuses diverged branches anyway, which would let a
/// missing --ff-only go unnoticed.
unittest
{
    import std.algorithm.searching : canFind;
    import std.process : environment;

    environment["GIT_CONFIG_COUNT"] = "1";
    environment["GIT_CONFIG_KEY_0"] = "pull.rebase";
    environment["GIT_CONFIG_VALUE_0"] = "false";
    scope (exit)
    {
        environment.remove("GIT_CONFIG_COUNT");
        environment.remove("GIT_CONFIG_KEY_0");
        environment.remove("GIT_CONFIG_VALUE_0");
    }

    immutable scratch = testDirectory("pullNested-diverged");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable a = makeRemote(scratch, "alpha", "main");
    immutable b = makeRemote(scratch, "beta", "main");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "/alpha/ " ~ a ~ "\n/beta/ " ~ b ~ "\n");
    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 0, text[1]);

    immutable alpha = buildPath(parent, "alpha");
    commit(alpha, "local work");
    immutable local = head(alpha);
    advance(scratch, "alpha", "main");
    advance(scratch, "beta", "main");

    assert(pullNested(scratch, parent, [], text) == 1);
    assert(head(alpha) == local);                                   // untouched
    assert(text[1].canFind("/alpha/: git pull --ff-only failed"));
    assert(head(buildPath(parent, "beta")) == head(buildPath(scratch, "beta-seed"))); // still pulled
}

/// On another branch: a warning, no switch, and the current branch is pulled.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pullNested-other-branch");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main", "feature");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "/alpha/ " ~ remote ~ "\n");
    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 0, text[1]);

    immutable alpha = buildPath(parent, "alpha");
    sh("-C", alpha, "checkout", "-q", "feature");
    advance(scratch, "alpha", "feature");

    assert(pullNested(scratch, parent, [], text) == 1);
    assert(text[1].canFind("on branch 'feature', but .gitrepos means 'main'; not switching"));
    assert(currentBranch(alpha) == "feature");
    assert(head(alpha) == head(buildPath(scratch, "alpha-seed")));   // feature was pulled
}

/// An existing directory that isn't a nested repo is skipped with a warning.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pullNested-not-repository");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "/alpha/ " ~ remote ~ "\n");
    buildPath(parent, "alpha").mkdirRecurse;

    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 1);
    assert(text[1].canFind("/alpha/ is not a git repository") && text[1].canFind("skipped"));
}

/// A listed branch the remote doesn't have: the clone stays, the error says why.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pullNested-missing-branch");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "/alpha/ " ~ remote ~ " nope\n");

    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 1);
    assert(text[1].canFind("cloned, but could not check out branch 'nope'"));
    assert(buildPath(parent, "alpha").exists);
}

/// File problems are reported but don't stop the pull; --fix repairs them.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pullNested-findings");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    gitrepos(parent, "/alpha/ " ~ remote ~ "\n", true); // no .gitignore block yet

    string[2] text;
    assert(pullNested(scratch, parent, [], text) == 1);
    assert(text[1].canFind("not in the managed block") && buildPath(parent, "alpha").exists);

    assert(pullNested(scratch, parent, ["--fix"], text) == 0, text[1]);
    assert(buildPath(parent, ".gitignore").readText.canFind("/alpha/"));
}

/// Usage: a positional argument, an unknown option, --help, a malformed file.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("pullNested-usage");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    string[2] text;
    assert(pullNested(scratch, scratch, ["alpha"], text) == 2);
    assert(text[1].canFind("unexpected argument 'alpha'"));
    assert(pullNested(scratch, scratch, ["--nonsense"], text) == 2);
    assert(pullNested(scratch, scratch, ["--help"], text) == 0);
    assert(text[0].canFind("Usage: pull-nested"));

    gitrepos(scratch, "/alpha/\n", true); // malformed
    assert(pullNested(scratch, scratch, [], text) == 2);
}
