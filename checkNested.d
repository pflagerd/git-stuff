/**
 * check-nested: reports problems with a parent directory's .gitignore and
 * .gitrepos, with the nested repos they list, and with git repositories
 * in the parent that .gitrepos doesn't list, without using the network.
 * With --fix, first repairs what can be repaired, which includes
 * registering those repositories as `add-nested <dir>` would
 * (ParentDirectory.registerUnlisted()). With -r/--recursive, the search
 * for unlisted repositories goes below the direct subdirectories
 * (ParentDirectory.checkDisk(Yes.recursive)); --fix then registers only
 * those whose nearest enclosing parent is the -C directory. With -f/--force
 * as well, the walk also goes into the directories that .gitignore lines
 * name (checkDisk(Yes.recursive, Yes.force)): those are still not
 * reported, but repositories inside them are. -f without -r only gets a
 * warning, since without -r there is no walk for it to change.
 *
 * Design: docs/nested-commands-proposal.md
 */
module checkNested;

import std.stdio : File;

import nestedCommon : CommonOptions, ExitStatus, loadParent, parseOptions, printFindings,
    reportNoCheckConflict;
import parentDirectory : ParentDirectory;

enum usage = "Usage: check-nested [-C <directory>] [-r [-f]] [--fix]

Reports problems with .gitignore, .gitrepos and the nested repos they
list, and git repositories in the directory that .gitrepos doesn't list.
Prints nothing when there are none. With --fix, also registers each of
those repositories as add-nested <directory> would, if it has an origin
remote and a current branch. With -r, looks below the direct
subdirectories too, except in directories whose name starts with . or
that a .gitignore line names; a repository found there belongs to the
nearest directory above it that is a git repository or has a .gitrepos,
and --fix registers it only when that is this directory. With -r -f, also
looks inside the directories that a .gitignore line names; such a
directory is still not reported itself, but repositories inside it are.
-f without -r has no effect. --no-check is refused, since checking is all
check-nested does. Exit status: 0 no problems, 1 problems remain, 2 bad
usage or a file that can't be read.
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

    import std.typecons : No, Yes;

    CommonOptions commonOptions;
    bool recursive;
    bool force;
    const parsed = parseOptions(args, commonOptions, output, errors, usage,
        "recursive|r", "Look below the direct subdirectories too.", &recursive,
        "force|f", "With -r, also look inside the directories that .gitignore names.", &force);
    if (!parsed.proceed)
    {
        return parsed.exitStatus;
    }
    // #29 decision 12: with the checks off, check-nested has nothing left
    // to do. parseOptions has already refused --no-check --fix; -r and -f
    // are check-nested's own options, so they are named here.
    if (commonOptions.noCheck)
    {
        string[] ownCheckOptions;
        if (recursive)
        {
            ownCheckOptions ~= "-r/--recursive";
        }
        if (force)
        {
            ownCheckOptions ~= "-f/--force";
        }
        reportNoCheckConflict("check-nested", ownCheckOptions, errors);
        errors.writeln("check-nested: --no-check leaves nothing to do: checking is all check-nested does");
        return ExitStatus.usage;
    }
    if (args.length > 1)
    {
        errors.writeln("check-nested: unexpected argument '", args[1], "'");
        return ExitStatus.usage;
    }
    // The proposal's answer 1b: -f without -r has no effect, because the
    // default mode doesn't walk. It is not refused, but she is told, in
    // case she meant -r -f. The exit status doesn't change.
    if (force && !recursive)
    {
        errors.writeln("check-nested: warning: -f/--force has no effect without -r/--recursive");
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
        const gitReposEntries = parentDirectory.registerUnlisted(recursive ? Yes.recursive : No.recursive,
            force ? Yes.force : No.force);
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

    immutable remaining = printFindings(parentDirectory.check
        ~ parentDirectory.checkDisk(recursive ? Yes.recursive : No.recursive, force ? Yes.force : No.force),
        errors);
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

/// -r: deeper unlisted repos are reported. --fix -r registers only those
/// whose nearest enclosing parent is the -C directory; the others keep
/// their "run check-nested -C <that directory> --fix" warning. Without
/// -r, neither is looked at.
unittest
{
    import std.algorithm.searching : canFind;
    import nestedCommon : makeRemote;

    immutable scratch = testDirectory("checkNested-fix-recursive");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "gamma", "main");
    void cloneTo(string clone)
    {
        git("clone", "-q", "-b", "main", remote, clone);
        git("-C", clone, "remote", "set-head", "origin", "main"); // not left to clone
    }
    immutable parent = buildPath(scratch, "parent");
    cloneTo(buildPath(parent, "tools", "gamma"));            // parent: the top
    cloneTo(buildPath(parent, "research", "unlistedhere")); // parent: research
    buildPath(parent, "research", ".gitrepos").write("");
    immutable ignoreText = "*.o\n";
    buildPath(parent, ".gitignore").write(ignoreText);

    string[2] text;
    assert(checkNested(scratch, parent, [], text) == 0); // default: direct entries only
    assert(text[0] == "" && text[1] == "");

    assert(checkNested(scratch, parent, ["-r"], text) == 1);
    assert(text[0] == "");
    assert(text[1] == "warning: " ~ buildPath(parent, "research", "unlistedhere") ~ ": /unlistedhere/"
        ~ " is a git repository but is not listed in " ~ buildPath(parent, "research", ".gitrepos")
        ~ "; run check-nested -C " ~ buildPath(parent, "research") ~ " --fix\n"
        ~ "warning: " ~ buildPath(parent, "tools", "gamma") ~ ": /tools/gamma/ is a git"
        ~ " repository but is not listed in " ~ buildPath(parent, ".gitrepos") ~ " (fixable with --fix)\n");
    assert(buildPath(parent, ".gitignore").readText == ignoreText); // untouched without --fix
    assert(!buildPath(parent, ".gitrepos").exists);

    assert(checkNested(scratch, parent, ["--recursive", "--fix"], text) == 1); // research's remains
    assert(text[0] == "added /tools/gamma/ " ~ remote ~ "\nfixed 1 problem(s)\n");
    assert(!text[1].canFind("/tools/gamma/") && text[1].canFind("/unlistedhere/"));
    assert(buildPath(parent, ".gitrepos").readText == "/tools/gamma/ " ~ remote ~ "\n");
    assert(buildPath(parent, ".gitignore").readText
        == "*.o\n" ~ beginMarker ~ "\n/tools/gamma/\n" ~ endMarker ~ "\n");
    assert(buildPath(parent, "research", ".gitrepos").readText == ""); // another parent's file: untouched

    // Running it where the warning says fixes the rest.
    assert(checkNested(scratch, buildPath(parent, "research"), ["--fix"], text) == 0);
    assert(checkNested(scratch, parent, ["-r"], text) == 0, text[0] ~ "|" ~ text[1]);
    assert(checkNested(scratch, parent, ["-r"], text) == 0);
    assert(text[0] == "" && text[1] == "");
}

/// -r -f: repos inside directories that .gitignore names are reported,
/// the named directories themselves are not. --fix -r -f registers only
/// the one whose nearest enclosing parent is the -C directory; the one
/// inside a listed repo keeps its "run check-nested -C <that repo>" hint.
/// -f without -r changes nothing but gets a warning.
unittest
{
    import std.algorithm.searching : canFind;
    import nestedCommon : makeRemote;

    immutable scratch = testDirectory("checkNested-force");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "secret", "main");
    void cloneTo(string clone)
    {
        git("clone", "-q", "-b", "main", remote, clone);
        git("-C", clone, "remote", "set-head", "origin", "main"); // not left to clone
    }
    immutable parent = buildPath(scratch, "parent");
    nestedRepo(parent, "alpha", "a.git");                      // listed, so named by the block
    cloneTo(buildPath(parent, "alpha", "inner"));              // alpha's business
    immutable secret = buildPath(parent, "private", "secret"); // private: named by hand
    cloneTo(secret);
    immutable ignoreText = "/private/
" ~ beginMarker ~ "
/alpha/
" ~ endMarker ~ "
";
    buildPath(parent, ".gitignore").write(ignoreText);
    buildPath(parent, ".gitrepos").write("/alpha/ a.git
");

    immutable innerWarning = "warning: " ~ buildPath(parent, "alpha", "inner") ~ ": /inner/ is a git"
        ~ " repository but is not listed in " ~ buildPath(parent, "alpha", ".gitrepos")
        ~ "; run check-nested -C " ~ buildPath(parent, "alpha") ~ " --fix
";
    immutable noEffect = "check-nested: warning: -f/--force has no effect without -r/--recursive
";

    string[2] text;
    assert(checkNested(scratch, parent, ["-r"], text) == 0); // without -f, named directories are skipped
    assert(text[0] == "" && text[1] == "");

    foreach (force; ["-f", "--force"])
    {
        assert(checkNested(scratch, parent, ["-r", force], text) == 1, force);
        assert(text[0] == "", force);
        assert(text[1] == innerWarning ~ "warning: " ~ secret ~ ": /private/secret/ is a git"
            ~ " repository but is not listed in " ~ buildPath(parent, ".gitrepos")
            ~ " (fixable with --fix)
", text[1]);
        // Without -r: no walk, so nothing more is found; only the warning.
        assert(checkNested(scratch, parent, [force], text) == 0, force);
        assert(text[0] == "" && text[1] == noEffect, text[1]);
    }
    assert(checkNested(scratch, parent, ["-f", "--fix"], text) == 0); // registers nothing
    assert(text[0] == "" && text[1] == noEffect, text[1]);
    assert(buildPath(parent, ".gitignore").readText == ignoreText);

    assert(checkNested(scratch, parent, ["-r", "-f", "--fix"], text) == 1); // alpha's inner remains
    assert(text[0] == "added /private/secret/ " ~ remote ~ "
fixed 1 problem(s)
", text[0]);
    assert(text[1] == innerWarning, text[1]);
    assert(buildPath(parent, ".gitrepos").readText == "/alpha/ a.git
/private/secret/ " ~ remote ~ "
");
    assert(buildPath(parent, ".gitignore").readText
        == "/private/
" ~ beginMarker ~ "
/alpha/
/private/secret/
" ~ endMarker ~ "
");
    assert(!buildPath(parent, "alpha", ".gitrepos").exists); // another repo's files: untouched
    assert(!buildPath(parent, "alpha", ".gitignore").exists);

    // Running it where the warning says fixes the rest.
    assert(checkNested(scratch, buildPath(parent, "alpha"), ["--fix"], text) == 0, text[1]);
    // "main" is recorded because "inner" isn't the name git clone would pick for secret.git.
    assert(text[0] == "added /inner/ " ~ remote ~ " main\nfixed 1 problem(s)\n", text[0]);
    assert(checkNested(scratch, parent, ["-r", "-f"], text) == 0, text[1]);
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
    assert(text[0].canFind("--recursive") && text[0].canFind("--force"));
    assert(checkNested(scratch, scratch, ["extra"], text) == 2);
    assert(text[1].canFind("unexpected argument 'extra'"));
    assert(checkNested(scratch, scratch, ["--nonsense"], text) == 2);
}

/// --no-check leaves check-nested nothing to do: exit 2, whatever it is
/// combined with, and the message names the conflicting options (#29
/// decision 12). Nothing is checked or written, even with findings.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("checkNested-no-check");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    parent.mkdirRecurse;
    immutable unsorted = "/beta/ b.git\n/alpha/ a.git\n";
    buildPath(parent, ".gitrepos").write(unsorted);

    immutable nothingToDo = "check-nested: --no-check leaves nothing to do: checking is all"
        ~ " check-nested does\n";
    string[2] text;
    assert(checkNested(scratch, parent, ["--no-check"], text) == 2);
    assert(text[0] == "" && text[1] == nothingToDo, text[1]);

    foreach (recursive; ["-r", "--recursive"])
    {
        assert(checkNested(scratch, parent, ["--no-check", recursive], text) == 2, recursive);
        assert(text[1] == "check-nested: --no-check can't be used with -r/--recursive: with the"
            ~ " checks off, there is nothing for it to do\n" ~ nothingToDo, text[1]);
    }
    foreach (force; ["-f", "--force"])
    {
        assert(checkNested(scratch, parent, ["--no-check", force], text) == 2, force);
        assert(text[0] == "" && text[1] == "check-nested: --no-check can't be used with -f/--force: with"
            ~ " the checks off, there is nothing for it to do\n" ~ nothingToDo, text[1]);
    }
    assert(checkNested(scratch, parent, ["-f", "--no-check", "-r"], text) == 2);
    assert(text[1] == "check-nested: --no-check can't be used with -r/--recursive, -f/--force: with"
        ~ " the checks off, there is nothing for them to do\n" ~ nothingToDo, text[1]);

    assert(checkNested(scratch, parent, ["--fix", "--no-check"], text) == 2);
    assert(text[1].canFind("--no-check can't be used with --fix"), text[1]);
    assert(!text[1].canFind("warning:"));
    assert(buildPath(parent, ".gitrepos").readText == unsorted); // untouched
    assert(!buildPath(parent, ".gitignore").exists);
}
