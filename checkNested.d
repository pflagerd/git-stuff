/**
 * check-nested: reports problems with a parent directory's .gitignore and
 * .gitrepos, and with the nested repos they list, without using the
 * network. With --fix, first repairs what can be repaired.
 *
 * Design: docs/nested-commands-proposal.md
 */
module checkNested;

import std.stdio : File;

import nestedCommand : CommonOptions, ExitStatus, loadParent, parseOptions, printFindings;
import parentDirectory : ParentDirectory;

enum usage = "Usage: check-nested [-C <directory>] [--fix]

Reports problems with .gitignore, .gitrepos and the nested repos they
list. Prints nothing when there are none. Exit status: 0 no problems,
1 problems remain, 2 bad usage or a file that can't be read.
";

/**
 * Does all of check-nested's work; main() only calls this, so tests can run
 * it in-process with `output` and `errors` captured.
 *
 * Returns: the exit status.
 */
int run(string[] args, File output, File errors)
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : count;

    CommonOptions common;
    const parsed = parseOptions(args, common, output, errors, usage);
    if (!parsed.proceed)
    {
        return parsed.exitStatus;
    }
    if (args.length > 1)
    {
        errors.writeln("check-nested: unexpected argument '", args[1], "'");
        return ExitStatus.usage;
    }

    ParentDirectory parent;
    if (!loadParent("check-nested", common.directory, parent, errors))
    {
        return ExitStatus.usage;
    }

    if (common.fix)
    {
        immutable fixable = parent.check.filter!(f => f.fixable).count;
        parent.fix();
        try
        {
            parent.write();
        }
        catch (Exception e)
        {
            errors.writeln("check-nested: could not write the fixed files: ", e.msg);
            return ExitStatus.findings;
        }
        if (fixable)
        {
            output.writeln("fixed ", fixable, " problem(s)");
            // Output is buffered when it isn't a terminal; flush so this line
            // comes before the warnings that follow on the error stream.
            output.flush();
        }
    }

    immutable remaining = printFindings(parent.check ~ parent.checkDisk, errors);
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
    import nestedCommand : captured, git;
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
