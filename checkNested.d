/**
 * check-nested: reports problems with a parent directory's .gitignore and
 * .gitrepos, with the nested repos they list, and with git repositories
 * in the parent that .gitrepos doesn't list, without using the network.
 * With --fix, first repairs what can be repaired, which includes
 * registering those repositories as `add-nested <dir>` would
 * (ParentDirectory.registerUnlisted()).
 *
 * Design: docs/nested-commands-proposal.md
 */
module checkNested;

import std.stdio : File;

import nestedCommon : CommonOptions, ExitStatus, loadParent, parseOptions, printFindings;
import parentDirectory : ParentDirectory;

enum usage = "Usage: check-nested [-C <directory>] [--fix]

Reports problems with .gitignore, .gitrepos and the nested repos they
list, and git repositories in the directory that .gitrepos doesn't list.
Prints nothing when there are none. With --fix, also registers each of
those repositories as add-nested <directory> would, if it has an origin
remote and a current branch. Exit status: 0 no problems,
1 problems remain, 2 bad usage or a file that can't be read.
";

/**
 * Does all of check-nested's work; main() only calls this, so tests can run
 * it in-process with `output` and `errors` captured.
 *
 * Returns: the exit status.
 */
ExitStatus run(string[] args, File output, File errors)
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : count;

    CommonOptions commonOptions;
    const parsed = parseOptions(args, commonOptions, output, errors, usage);
    if (!parsed.proceed)
    {
        return parsed.exitStatus;
    }
    if (args.length > 1)
    {
        errors.writeln("check-nested: unexpected argument '", args[1], "'");
        return ExitStatus.usage;
    }

    ParentDirectory parentDirectory;
    if (!loadParent("check-nested", commonOptions.directory, parentDirectory, errors))
    {
        return ExitStatus.usage;
    }

    if (commonOptions.fix)
    {
        immutable fixable = parentDirectory.check.filter!(finding => finding.fixable).count;
        // Registered first, so fix() then sorts them into both files.
        const gitReposEntries = parentDirectory.registerUnlisted();
        parentDirectory.fix();
        try
        {
            parentDirectory.write();
        }
        catch (Exception exception)
        {
            errors.writeln("check-nested: could not write the fixed files: ", exception.msg);
            return ExitStatus.findings;
        }
        foreach (gitReposEntry; gitReposEntries)
        {
            output.writeln("added ", gitReposEntry.directory, " ", gitReposEntry.url,
                gitReposEntry.branch.length ? " " ~ gitReposEntry.branch : "");
        }
        if (fixable + gitReposEntries.length)
        {
            output.writeln("fixed ", fixable + gitReposEntries.length, " problem(s)");
            // Output is buffered when it isn't a terminal; flush so this line
            // comes before the warnings that follow on the error stream.
            output.flush();
        }
    }

    immutable remaining = printFindings(parentDirectory.check ~ parentDirectory.checkDisk, errors);
    return remaining ? ExitStatus.findings : ExitStatus.ok;
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
    import nestedCommon : captured, git;
    import textFile : testDirectory;
    import gitIgnore : beginMarker, endMarker;

    /// Runs check-nested on `parent` with `extra` options; returns the exit
    /// status, and what went to output and errors.
    private int checkNested(string scratch, string parent, string[] extra, out string[2] text)
    {
        int status;
        text = captured(scratch, (File output, File errors) {
            status = run(["check-nested", "-C", parent] ~ extra, output, errors);
        });
        return status;
    }

    /// A parent directory with a nested repo `name` whose origin is `url`.
    private void nestedRepo(string parent, string name, string url)
    {
        git("init", "-q", buildPath(parent, name));
        git("-C", buildPath(parent, name), "remote", "add", "origin", url);
    }
}

/// Nothing to report: exit 0, and nothing printed at all.
unittest
{
    immutable scratch = testDirectory("checkNested-clean");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    nestedRepo(parent, "alpha", "git@github.com:pflagerd/alpha.git");
    buildPath(parent, ".gitignore").write(beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n");
    buildPath(parent, ".gitrepos").write("/alpha/ git@github.com:pflagerd/alpha.git\n");

    string[2] text;
    assert(checkNested(scratch, parent, [], text) == 0);
    assert(text[0] == "" && text[1] == "");
}

/// Findings from the files and from the disk: exit 1, files untouched.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("checkNested-findings");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    nestedRepo(parent, "alpha", "a.git");
    immutable reposText = "/beta/ b.git\n/alpha/ a.git\n"; // unsorted; beta missing
    buildPath(parent, ".gitrepos").write(reposText);

    string[2] text;
    assert(checkNested(scratch, parent, [], text) == 1);
    assert(text[0] == "");
    assert(text[1].canFind("warning: ") && text[1].canFind("not sorted")
        && text[1].canFind("(fixable with --fix)"));
    assert(text[1].canFind("/beta/ does not exist"));
    assert(buildPath(parent, ".gitrepos").readText == reposText);
    assert(!buildPath(parent, ".gitignore").exists);
}

/// --fix repairs, writes, says how many, and a second run is clean.
unittest
{
    immutable scratch = testDirectory("checkNested-fix");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    nestedRepo(parent, "alpha", "a.git");
    nestedRepo(parent, "beta", "b.git");
    buildPath(parent, ".gitignore").write("*.o\nalpha\n");                // loose line
    buildPath(parent, ".gitrepos").write("/beta/ b.git\n/alpha/ a.git\n"); // unsorted; beta not in block

    string[2] text;
    assert(checkNested(scratch, parent, ["--fix"], text) == 0);
    assert(text[0] == "fixed 3 problem(s)\n" && text[1] == "");
    assert(buildPath(parent, ".gitignore").readText
        == "*.o\n" ~ beginMarker ~ "\n/alpha/\n/beta/\n" ~ endMarker ~ "\n");
    assert(buildPath(parent, ".gitrepos").readText == "/alpha/ a.git\n/beta/ b.git\n");

    assert(checkNested(scratch, parent, [], text) == 0);
    assert(text[0] == "" && text[1] == "");
}

/// --fix with problems it can't fix: those remain, exit 1.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("checkNested-fix-unfixable");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    parent.mkdirRecurse;
    buildPath(parent, ".gitrepos").write("/gone/ g.git\n");

    string[2] text;
    assert(checkNested(scratch, parent, ["--fix"], text) == 1);
    assert(text[0] == "fixed 1 problem(s)\n"); // /gone/ added to the block
    assert(text[1].canFind("/gone/ does not exist") && !text[1].canFind("(fixable with --fix)"));
}

/// Unlisted nested repos: reported, fixable only when add-nested could
/// register them unaided; --fix registers those in both files, says so,
/// counts them, and a second run doesn't report them.
unittest
{
    import std.algorithm.searching : canFind;
    import nestedCommon : makeRemote;

    immutable scratch = testDirectory("checkNested-fix-unlisted");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    nestedRepo(parent, "alpha", "a.git"); // listed
    buildPath(parent, ".gitignore").write("*.o\n" ~ beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n");
    immutable reposText = "/alpha/ a.git\n";
    buildPath(parent, ".gitrepos").write(reposText);

    // beta: a clone on its remote's default branch, so add-nested would
    // leave the branch out. origin/HEAD is set explicitly, not left to clone.
    immutable remote = makeRemote(scratch, "beta", "main");
    git("clone", "-q", "-b", "main", remote, buildPath(parent, "beta"));
    git("-C", buildPath(parent, "beta"), "remote", "set-head", "origin", "main");
    // lonely: no origin remote, so not fixable.
    git("init", "-q", "-b", "main", buildPath(parent, "lonely"));

    string[2] text;
    assert(checkNested(scratch, parent, [], text) == 1);
    assert(text[0] == "");
    assert(text[1].canFind("/beta/ is a git repository but is not listed in "
        ~ buildPath(parent, ".gitrepos") ~ " (fixable with --fix)\n"));
    assert(text[1].canFind("add it with add-nested --url <url> lonely\n")); // no "(fixable"
    assert(buildPath(parent, ".gitrepos").readText == reposText); // untouched without --fix

    assert(checkNested(scratch, parent, ["--fix"], text) == 1); // lonely remains
    assert(text[0] == "added /beta/ " ~ remote ~ "\nfixed 1 problem(s)\n");
    assert(!text[1].canFind("/beta/") && text[1].canFind("/lonely/"));
    assert(buildPath(parent, ".gitrepos").readText == "/alpha/ a.git\n/beta/ " ~ remote ~ "\n");
    assert(buildPath(parent, ".gitignore").readText
        == "*.o\n" ~ beginMarker ~ "\n/alpha/\n/beta/\n" ~ endMarker ~ "\n");

    // With lonely gone, nothing is left to report or fix.
    buildPath(parent, "lonely").rmdirRecurse;
    assert(checkNested(scratch, parent, [], text) == 0);
    assert(text[0] == "" && text[1] == "");
    assert(checkNested(scratch, parent, ["--fix"], text) == 0);
    assert(text[0] == "" && text[1] == "");
}

/// A file that won't parse: exit 2, message naming the file and line.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("checkNested-malformed");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    parent.mkdirRecurse;
    buildPath(parent, ".gitrepos").write("/alpha/ a.git\n/beta/\n");

    string[2] text;
    assert(checkNested(scratch, parent, ["--fix"], text) == 2);
    assert(text[1].canFind(buildPath(parent, ".gitrepos") ~ ": line 2: "));
    assert(buildPath(parent, ".gitrepos").readText == "/alpha/ a.git\n/beta/\n"); // untouched
}

/// Usage: --help exits 0; a positional argument or unknown option exits 2.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("checkNested-usage");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    string[2] text;
    assert(checkNested(scratch, scratch, ["--help"], text) == 0);
    assert(text[0].canFind("Usage: check-nested"));
    assert(checkNested(scratch, scratch, ["extra"], text) == 2);
    assert(text[1].canFind("unexpected argument 'extra'"));
    assert(checkNested(scratch, scratch, ["--nonsense"], text) == 2);
}
