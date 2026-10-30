/**
 * What the nested-repo commands (check-nested, add-nested, remove-nested,
 * pull-nested) share: exit statuses, option parsing, printing findings, the
 * branch rules, and a few git queries.
 *
 * Design: docs/nested-commands-proposal.md
 */
module nestedCommon;

import std.stdio : File;

import finding : Finding;
import parentDirectory : ParentDirectory;

/// Exit statuses, the same three-way convention as GNU grep.
enum ExitStatus : int
{
    ok = 0,       /// did its job, and no findings remain
    findings = 1, /// findings remain, or a git command failed for some repo
    usage = 2,    /// couldn't start: bad usage, or a file that won't parse
}

// --- options -------------------------------------------------------------------

/// The options every command takes.
struct CommonOptions
{
    string directory = "."; /// -C: the parent directory to work in
    bool fix;               /// --fix: repair fixable findings first
}

/// What parseOptions decided.
struct Parsed
{
    bool proceed;   /// true: run the command; false: exit with `exitStatus`

    /**
     * The status to exit with when `proceed` is false. parseOptions sets
     * one of:
     * - ExitStatus.ok (0): -h or --help was given, and the usage has been
     *   printed to the output;
     * - ExitStatus.usage (2): an unknown or malformed option (e.g. a
     *   missing value), and a message has been printed to the errors.
     *
     * It is never ExitStatus.findings (1). When `proceed` is true it is
     * left at ExitStatus.ok and callers ignore it.
     */
    int exitStatus;
}

/**
 * Parses -C, --fix and -h/--help, plus any options of one command passed as
 * `extra` (in std.getopt's form: name, help text, pointer, ...). What is
 * left in `args` afterwards is the program name followed by the positional
 * arguments.
 *
 * -h/--help prints `usage` and the option list to `output` (exit 0). An
 * unknown or malformed option prints a message to `errors` (exit 2).
 * Options are case-sensitive, so -C is not -c.
 */
Parsed parseOptions(Extra...)(ref string[] args, ref CommonOptions common,
    File output, File errors, string usage, Extra extra)
{
    import std.getopt : config, defaultGetoptFormatter, getopt, GetOptException;
    import std.conv : ConvException;

    try
    {
        auto result = getopt(args, config.caseSensitive,
            "C", "Work in <directory> instead of the current directory.", &common.directory,
            "fix", "Repair fixable findings in .gitignore and .gitrepos first.", &common.fix,
            extra);
        if (result.helpWanted)
        {
            defaultGetoptFormatter(output.lockingTextWriter, usage, result.options);
            return Parsed(false, ExitStatus.ok);
        }
    }
    catch (GetOptException e)
    {
        errors.writeln(args.length ? args[0] : "nested", ": ", e.msg);
        return Parsed(false, ExitStatus.usage);
    }
    catch (ConvException e) // e.g. a value of the wrong type
    {
        errors.writeln(args.length ? args[0] : "nested", ": ", e.msg);
        return Parsed(false, ExitStatus.usage);
    }
    return Parsed(true, ExitStatus.ok);
}

// --- loading ---------------------------------------------------------------------

/**
 * Loads the ParentDirectory for `directory` into `parent`. On failure prints
 * why to `errors`, prefixed with `program` and naming the file (and line,
 * for a parse error), and returns false: the caller exits with
 * ExitStatus.usage, having changed nothing.
 */
bool loadParent(string program, string directory, out ParentDirectory parent, File errors)
{
    import std.file : FileException;
    import std.path : buildPath;
    import std.utf : UTFException;
    import gitIgnore : GitIgnoreException;
    import gitRepos : GitReposException;

    try
    {
        parent = new ParentDirectory(directory);
        return true;
    }
    catch (GitIgnoreException e)
    {
        errors.writeln(program, ": ", buildPath(directory, ".gitignore"), ": ", e.msg);
    }
    catch (GitReposException e)
    {
        errors.writeln(program, ": ", buildPath(directory, ".gitrepos"), ": ", e.msg);
    }
    catch (UTFException e)
    {
        errors.writeln(program, ": a file in ", directory, " is not valid UTF-8: ", e.msg);
    }
    catch (FileException e)
    {
        errors.writeln(program, ": ", e.msg);
    }
    return false;
}

// --- output --------------------------------------------------------------------

/// Prints each finding to `errors` as "warning: <message>", noting the
/// fixable ones. Returns: how many were printed.
size_t printFindings(const Finding[] findings, File errors)
{
    foreach (f; findings)
    {
        errors.writeln("warning: ", f.message, f.fixable ? " (fixable with --fix)" : "");
    }
    return findings.length;
}

// --- branch rules --------------------------------------------------------------

/// The last component of a .gitrepos directory: "/tools/blog/" -> "blog".
string lastComponent(string directory) @safe pure
{
    import std.path : baseName;
    import std.string : strip;

    return directory.strip("/").baseName;
}

/**
 * Whether `directory`'s last component differs from the name `git clone`
 * would choose for `url`. If git couldn't guess a name either, they count
 * as differing; both branch rules below treat that case the same way.
 */
bool namesDiffer(string directory, string url) @safe
{
    import gitCloneDirectoryName : gitCloneDirectoryName, NoDirNameException;

    try
    {
        return lastComponent(directory) != gitCloneDirectoryName(url);
    }
    catch (NoDirNameException)
    {
        return true;
    }
}

/**
 * The branch a fresh clone should end up on (decision 6 part 3):
 * - the listed branch, if there is one;
 * - otherwise, if the directory's name differs from the name `git clone`
 *   would choose, a branch named after the directory, if the remote has it;
 * - otherwise "", meaning the remote's default (what the clone checked out).
 *
 * `remoteHasBranch` answers "does the remote have this branch?"; passing it
 * in keeps this function testable without a repository.
 */
string branchAfterClone(string directory, string url, string listedBranch,
    scope bool delegate(string) remoteHasBranch)
{
    if (listedBranch.length)
    {
        return listedBranch;
    }
    immutable named = lastComponent(directory);
    if (namesDiffer(directory, url) && remoteHasBranch(named))
    {
        return named;
    }
    return "";
}

/**
 * Whether add-nested may leave `currentBranch` out of .gitrepos (decision 3,
 * option a'): only if a fresh clone of a line without a branch would end up
 * on that same branch.
 *
 * - If branchAfterClone names a branch, it must be `currentBranch`.
 * - If it means the default and the names differ, record the branch: should
 *   the remote later gain a branch named after the directory, a line without
 *   a branch would quietly change meaning.
 * - Otherwise the current branch must be the remote's default, which must be
 *   known (`remoteDefault` is "" when it isn't).
 */
bool branchCanBeOmitted(string directory, string url, string currentBranch,
    scope bool delegate(string) remoteHasBranch, string remoteDefault)
{
    if (currentBranch.length == 0)
    {
        return false;
    }
    immutable afterClone = branchAfterClone(directory, url, "", remoteHasBranch);
    if (afterClone.length)
    {
        return currentBranch == afterClone;
    }
    if (namesDiffer(directory, url))
    {
        return false;
    }
    return remoteDefault.length && currentBranch == remoteDefault;
}

// --- git queries ---------------------------------------------------------------

/// The repository's current branch, or "" for a detached HEAD or an error.
string currentBranch(string repository)
{
    import std.process : execute;
    import std.string : strip;

    const r = execute(["git", "-C", repository, "symbolic-ref", "--quiet", "--short", "HEAD"]);
    return r.status == 0 ? r.output.strip : "";
}

/// Whether the repository has `refs/remotes/origin/<branch>` locally.
bool remoteHasBranch(string repository, string branch)
{
    import std.process : execute;

    const r = execute(["git", "-C", repository, "rev-parse", "--verify", "--quiet",
        "refs/remotes/origin/" ~ branch]);
    return r.status == 0;
}

/**
 * The remote's default branch as recorded locally in
 * `refs/remotes/origin/HEAD` ("main" from "origin/main"), or "" if it isn't
 * recorded (e.g. after `git init` and `git remote add`) or on any error.
 */
string remoteDefaultBranch(string repository)
{
    import std.algorithm.searching : startsWith;
    import std.process : execute;
    import std.string : strip;

    const r = execute(["git", "-C", repository, "symbolic-ref", "--quiet", "--short",
        "refs/remotes/origin/HEAD"]);
    immutable name = r.output.strip;
    if (r.status != 0 || !name.startsWith("origin/"))
    {
        return "";
    }
    return name["origin/".length .. $];
}

// --- running git -----------------------------------------------------------------

/**
 * Runs git with `args`, its output going straight to `output` and `errors`
 * (so progress and messages appear as they happen), and its input from the
 * terminal (so ssh can still ask for a passphrase). Never through a shell.
 *
 * Returns: whether git succeeded.
 */
bool runGit(string[] args, File output, File errors)
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

/**
 * Clones `url` into `onDisk` (which must not exist) and checks out the
 * branch branchAfterClone gives for the nested `directory` and
 * `listedBranch`. With no branch listed and a directory named differently
 * from the clone name, but no such branch on the remote, it notes on
 * `output` that the clone stays on the default branch. add-nested --clone
 * and pull-nested both clone this way.
 *
 * Returns: "" on success, else what went wrong. If the clone itself failed,
 * git leaves nothing behind; if only the checkout failed, the clone stays.
 */
string cloneNested(string onDisk, string directory, string url, string listedBranch,
    File output, File errors)
{
    if (!runGit(["clone", url, onDisk], output, errors))
    {
        return "git clone failed";
    }
    immutable target = branchAfterClone(directory, url, listedBranch,
        (string b) => remoteHasBranch(onDisk, b));
    if (target.length && currentBranch(onDisk) != target)
    {
        if (!runGit(["-C", onDisk, "checkout", "--quiet", target], output, errors))
        {
            return "cloned, but could not check out branch '" ~ target ~ "'";
        }
    }
    else if (target.length == 0 && listedBranch.length == 0 && namesDiffer(directory, url))
    {
        output.writeln("no branch \"", lastComponent(directory),
            "\" on the remote; staying on ", currentBranch(onDisk));
    }
    return "";
}

// --- tests: options ------------------------------------------------------------

version (unittest)
{
    import std.file : readText, rmdirRecurse;
    import std.path : buildPath;
    import textFile : testDirectory;

    /// Runs `body` with `output` and `errors` going to files in `directory`,
    /// and returns what was written to each. (Test builds only; the commands'
    /// tests use it too.)
    string[2] captured(string directory, scope void delegate(File, File) body)
    {
        immutable outPath = buildPath(directory, "output");
        immutable errPath = buildPath(directory, "errors");
        {
            auto output = File(outPath, "w");
            auto errors = File(errPath, "w");
            body(output, errors);
        } // both closed here, so everything is flushed
        return [outPath.readText, errPath.readText];
    }
}

/// Defaults; -C and --fix; positional arguments are left in args.
unittest
{
    immutable directory = testDirectory("nestedCommon-options");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto text = captured(directory, (File output, File errors) {
        string[] args = ["add-nested", "alpha"];
        CommonOptions common;
        assert(parseOptions(args, common, output, errors, "usage").proceed);
        assert(common.directory == "." && !common.fix);
        assert(args == ["add-nested", "alpha"]);

        args = ["add-nested", "-C", "/tmp/p", "--fix", "alpha", "beta"];
        common = CommonOptions.init;
        assert(parseOptions(args, common, output, errors, "usage").proceed);
        assert(common.directory == "/tmp/p" && common.fix);
        assert(args == ["add-nested", "alpha", "beta"]);
    });
    assert(text[0] == "" && text[1] == "");
}

/// A command's own options are parsed alongside the shared ones.
unittest
{
    immutable directory = testDirectory("nestedCommon-options-extra");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    captured(directory, (File output, File errors) {
        string[] args = ["add-nested", "--branch", "dev", "--fix", "alpha"];
        CommonOptions common;
        string branch;
        assert(parseOptions(args, common, output, errors, "usage",
            "branch", "Record this branch.", &branch).proceed);
        assert(branch == "dev" && common.fix && args == ["add-nested", "alpha"]);
    });
}

/// -h/--help prints usage to output and exits 0; nothing goes to errors.
unittest
{
    import std.algorithm.searching : canFind;

    immutable directory = testDirectory("nestedCommon-help");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    foreach (flag; ["-h", "--help"])
    {
        auto text = captured(directory, (File output, File errors) {
            string[] args = ["check-nested", flag];
            CommonOptions common;
            const p = parseOptions(args, common, output, errors, "Usage: check-nested [options]");
            assert(!p.proceed && p.exitStatus == ExitStatus.ok);
        });
        assert(text[0].canFind("Usage: check-nested") && text[0].canFind("-C"), flag);
        assert(text[1] == "", flag);
    }
}

/// An unknown option, a missing value, or a wrong case is a usage error (2).
unittest
{
    import std.algorithm.searching : canFind;

    immutable directory = testDirectory("nestedCommon-usage");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    foreach (bad; [["check-nested", "--nonsense"], ["check-nested", "-C"],
                   ["check-nested", "-c", "/tmp"], ["check-nested", "--FIX"]])
    {
        auto text = captured(directory, (File output, File errors) {
            string[] args = bad.dup;
            CommonOptions common;
            const p = parseOptions(args, common, output, errors, "usage");
            assert(!p.proceed && p.exitStatus == ExitStatus.usage, bad[1]);
        });
        assert(text[0] == "" && text[1].canFind("check-nested: "), bad[1]);
    }
}

// --- tests: output -------------------------------------------------------------

/// Findings are printed as warnings, fixable ones noted.
unittest
{
    immutable directory = testDirectory("nestedCommon-findings");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto text = captured(directory, (File output, File errors) {
        assert(printFindings([
            Finding("", ".gitrepos: entries are not sorted by directory", true),
            Finding("/a/", ".gitrepos: /a/ is listed 2 times", false),
        ], errors) == 2);
    });
    assert(text[0] == "");
    assert(text[1] == "warning: .gitrepos: entries are not sorted by directory (fixable with --fix)\n"
        ~ "warning: .gitrepos: /a/ is listed 2 times\n");
}

// --- tests: branch rules -------------------------------------------------------

/// lastComponent and namesDiffer.
unittest
{
    assert(lastComponent("/blog/") == "blog");
    assert(lastComponent("/tools/blog/") == "blog");
    assert(!namesDiffer("/alpha/", "git@github.com:pflagerd/alpha.git"));
    assert(!namesDiffer("/tools/alpha/", "git@github.com:pflagerd/alpha.git"));
    assert(namesDiffer("/blog/", "git@github.com:pflagerd/blog-bootstrap"));
}

/// branchAfterClone: listed branch; directory-named branch if the remote has
/// it; otherwise the default (""). #2's example included.
unittest
{
    bool has(string b) { return b == "blog"; }
    bool none(string b) { return false; }

    immutable bootstrap = "git@github.com:pflagerd/blog-bootstrap";
    assert(branchAfterClone("/blog/", bootstrap, "bok-blog", &none) == "bok-blog"); // #2
    assert(branchAfterClone("/blog/", bootstrap, "", &has) == "blog");
    assert(branchAfterClone("/blog/", bootstrap, "", &none) == "");
    // Names match: never a directory-named branch, even if one exists.
    assert(branchAfterClone("/blog/", "git@github.com:pflagerd/blog.git", "", &has) == "");
}

/// branchCanBeOmitted: decision 3 (a') in every case.
unittest
{
    bool has(string b) { return b == "blog"; }
    bool none(string b) { return false; }

    immutable bootstrap = "git@github.com:pflagerd/blog-bootstrap";
    immutable same = "git@github.com:pflagerd/blog.git";

    // Names differ, remote has "blog": omit only when on "blog".
    assert(branchCanBeOmitted("/blog/", bootstrap, "blog", &has, "master"));
    assert(!branchCanBeOmitted("/blog/", bootstrap, "master", &has, "master"));
    // Names differ, no "blog" on the remote: always record, even on the default.
    assert(!branchCanBeOmitted("/blog/", bootstrap, "master", &none, "master"));
    // Names match: omit only when on the known default.
    assert(branchCanBeOmitted("/blog/", same, "main", &none, "main"));
    assert(!branchCanBeOmitted("/blog/", same, "dev", &none, "main"));
    assert(!branchCanBeOmitted("/blog/", same, "main", &none, "")); // default unknown
    // Detached HEAD: nothing to omit.
    assert(!branchCanBeOmitted("/blog/", same, "", &none, ""));
}

// --- tests: git queries --------------------------------------------------------

version (unittest)
{
    /// Runs git with `args`, failing the test if it fails. (Test builds only;
    /// the commands' tests use it too.)
    void git(string[] args...)
    {
        import std.process : execute;

        const r = execute(["git"] ~ args);
        assert(r.status == 0, r.output);
    }
}

/// The queries against real local repositories.
unittest
{
    immutable directory = testDirectory("nestedCommon-git");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    // A remote with branches develop (default) and blog, and one commit.
    immutable remote = buildPath(directory, "remote.git");
    immutable seed = buildPath(directory, "seed");
    git("init", "-q", "--bare", "-b", "develop", remote);
    git("init", "-q", "-b", "develop", seed);
    git("-C", seed, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
        "--allow-empty", "-m", "init");
    git("-C", seed, "push", "-q", remote, "develop", "develop:blog");

    immutable cloned = buildPath(directory, "cloned");
    git("clone", "-q", remote, cloned);
    assert(currentBranch(cloned) == "develop");
    assert(remoteDefaultBranch(cloned) == "develop");
    assert(remoteHasBranch(cloned, "blog"));
    assert(!remoteHasBranch(cloned, "nope"));

    git("-C", cloned, "checkout", "-q", "--detach");
    assert(currentBranch(cloned) == "");

    // init + remote add + fetch: no origin/HEAD, so the default is unknown.
    immutable added = buildPath(directory, "added");
    git("init", "-q", added);
    git("-C", added, "remote", "add", "origin", remote);
    git("-C", added, "fetch", "-q", "origin");
    assert(remoteDefaultBranch(added) == "");
    assert(remoteHasBranch(added, "blog"));

    // A repository with no remote: no default, no remote branches.
    immutable plain = buildPath(directory, "plain");
    git("init", "-q", plain);
    assert(remoteDefaultBranch(plain) == "" && !remoteHasBranch(plain, "blog"));
}
