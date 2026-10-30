/**
 * remove-nested: unregisters nested repos from a parent directory's
 * .gitrepos and .gitignore. It never deletes a directory.
 *
 * Design: docs/nested-commands-proposal.md
 */
module removeNested;

import std.stdio : File;

import nestedCommon : CommonOptions, ExitStatus, loadParent, parseOptions, printFindings;
import parentDirectory : ParentDirectory;

enum usage = "Usage: remove-nested [-C <directory>] [--fix] <nested directory>...

Removes each nested directory from .gitrepos and from the managed block of
.gitignore. The directory itself is never touched. Exit status: 0 done,
1 something wasn't registered or problems remain, 2 bad usage or a file
that can't be read.
";

/**
 * Does all of remove-nested's work; main() only calls this, so tests can run
 * it in-process with `output` and `errors` captured.
 *
 * A directory in neither file gets a warning, and the others are still
 * removed: removing what isn't there changes nothing, so the files end up as
 * she asked.
 *
 * Returns: the exit status.
 */
ExitStatus run(string[] args, File output, File errors)
{
    import std.algorithm.searching : any, canFind;
    import std.file : exists;
    import std.path : buildPath;
    import gitRepos : GitRepos;

    CommonOptions common;
    const parsed = parseOptions(args, common, output, errors, usage);
    if (!parsed.proceed)
    {
        return parsed.exitStatus;
    }
    if (args.length < 2)
    {
        errors.writeln("remove-nested: no nested directory given");
        return ExitStatus.usage;
    }

    ParentDirectory parent;
    if (!loadParent("remove-nested", common.directory, parent, errors))
    {
        return ExitStatus.usage;
    }

    bool changed = false;
    if (common.fix)
    {
        changed = parent.check.any!(f => f.fixable);
        parent.fix();
    }

    bool notFound = false;
    foreach (argument; args[1 .. $])
    {
        immutable directory = GitRepos.normalizeDirectory(argument);
        immutable inRepos = parent.gitRepos.entries.any!(e => e.directory == directory);
        immutable inIgnore = parent.gitIgnore.nested.canFind(directory);

        if (directory.length == 0 || !parent.remove(directory))
        {
            errors.writeln("warning: ", argument, " is in neither ", parent.gitRepos.path,
                " nor the managed block of ", parent.gitIgnore.path);
            notFound = true;
            continue;
        }
        changed = true;

        immutable from = inRepos && inIgnore ? ".gitrepos and .gitignore"
            : inRepos ? ".gitrepos" : ".gitignore";
        immutable onDisk = buildPath(common.directory, directory[1 .. $ - 1]);
        output.writeln("removed ", directory, " from ", from,
            onDisk.exists ? "; " ~ onDisk ~ " is still on disk (remove-nested never deletes directories)"
                : "");
    }

    if (changed)
    {
        try
        {
            parent.write();
        }
        catch (Exception e)
        {
            errors.writeln("remove-nested: could not write the files: ", e.msg);
            return ExitStatus.findings;
        }
    }
    output.flush(); // before the warnings that follow on the error stream

    immutable remaining = printFindings(parent.check, errors);
    return notFound || remaining ? ExitStatus.findings : ExitStatus.ok;
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
    import nestedCommon : captured;
    import textFile : testDirectory;
    import gitIgnore : beginMarker, endMarker;

    /// Runs remove-nested on `parent` with `arguments`; returns the exit
    /// status, and what went to output and errors.
    private int removeNested(string scratch, string parent, string[] arguments, out string[2] text)
    {
        int status;
        text = captured(scratch, (File output, File errors) {
            status = run(["remove-nested", "-C", parent] ~ arguments, output, errors);
        });
        return status;
    }

    /// A parent directory registering /alpha/ and /beta/ in both files.
    private string twoRepos(string scratch)
    {
        immutable parent = buildPath(scratch, "parent");
        parent.mkdirRecurse;
        buildPath(parent, ".gitignore").write(
            "*.o\n" ~ beginMarker ~ "\n/alpha/\n/beta/\n" ~ endMarker ~ "\n");
        buildPath(parent, ".gitrepos").write("/alpha/ a.git\n/beta/ b.git dev\n");
        return parent;
    }
}

/// Removing one repo takes it out of both files, in any slash form.
unittest
{
    immutable scratch = testDirectory("removeNested-one");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = twoRepos(scratch);
    string[2] text;
    assert(removeNested(scratch, parent, ["alpha"], text) == 0);
    assert(text[0] == "removed /alpha/ from .gitrepos and .gitignore\n" && text[1] == "");
    assert(buildPath(parent, ".gitrepos").readText == "/beta/ b.git dev\n");
    assert(buildPath(parent, ".gitignore").readText
        == "*.o\n" ~ beginMarker ~ "\n/beta/\n" ~ endMarker ~ "\n");
}

/// Several at once; removing the last one removes the block, keeping the rest.
unittest
{
    immutable scratch = testDirectory("removeNested-several");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = twoRepos(scratch);
    string[2] text;
    assert(removeNested(scratch, parent, ["/alpha/", "beta/"], text) == 0);
    assert(buildPath(parent, ".gitrepos").readText == "");
    assert(buildPath(parent, ".gitignore").readText == "*.o\n");
}

/// The directory on disk is never touched, and the message says so.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("removeNested-on-disk");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = twoRepos(scratch);
    immutable alpha = buildPath(parent, "alpha");
    alpha.mkdirRecurse;
    buildPath(alpha, "keep.txt").write("still here\n");

    string[2] text;
    assert(removeNested(scratch, parent, ["alpha"], text) == 0);
    assert(text[0].canFind("is still on disk (remove-nested never deletes directories)"));
    assert(buildPath(alpha, "keep.txt").readText == "still here\n");
}

/// A directory in neither file: warning, exit 1, and the others still go.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("removeNested-not-found");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = twoRepos(scratch);
    string[2] text;
    assert(removeNested(scratch, parent, ["gamma", "alpha"], text) == 1);
    assert(text[1].canFind("warning: gamma is in neither"));
    assert(text[0] == "removed /alpha/ from .gitrepos and .gitignore\n");
    assert(buildPath(parent, ".gitrepos").readText == "/beta/ b.git dev\n");
}

/// Nothing to remove and nothing fixed: the files aren't rewritten.
unittest
{
    immutable scratch = testDirectory("removeNested-unchanged");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    import std.file : DirEntry;

    // writeAtomically renames a new file over the old one, so a rewritten
    // file has a new inode even when its text is identical; comparing text
    // alone wouldn't notice a needless rewrite.
    immutable parent = twoRepos(scratch);
    immutable reposFile = buildPath(parent, ".gitrepos");
    immutable ignoreFile = buildPath(parent, ".gitignore");
    immutable reposInode = DirEntry(reposFile).statBuf.st_ino;
    immutable ignoreInode = DirEntry(ignoreFile).statBuf.st_ino;

    string[2] text;
    assert(removeNested(scratch, parent, ["gamma"], text) == 1);
    assert(DirEntry(reposFile).statBuf.st_ino == reposInode);
    assert(DirEntry(ignoreFile).statBuf.st_ino == ignoreInode);

    // And a real removal does rewrite (so the check above can tell).
    assert(removeNested(scratch, parent, ["alpha"], text) == 0);
    assert(DirEntry(reposFile).statBuf.st_ino != reposInode);
}

/// Present in only one file: removed from that one, and the message says which.
unittest
{
    immutable scratch = testDirectory("removeNested-one-file");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    parent.mkdirRecurse;
    buildPath(parent, ".gitignore").write(beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n");
    buildPath(parent, ".gitrepos").write("/beta/ b.git\n");

    string[2] text;
    assert(removeNested(scratch, parent, ["alpha", "beta"], text) == 0);
    assert(text[0] == "removed /alpha/ from .gitignore\nremoved /beta/ from .gitrepos\n");
}

/// Remaining problems are reported after removing; --fix repairs them first.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("removeNested-findings");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    parent.mkdirRecurse;
    buildPath(parent, ".gitignore").write("alpha\n"); // loose line for /alpha/
    buildPath(parent, ".gitrepos").write("/alpha/ a.git\n/beta/ b.git\n");

    string[2] text;
    assert(removeNested(scratch, parent, ["beta"], text) == 1);
    assert(text[1].canFind("outside the managed block") && text[1].canFind("(fixable with --fix)"));

    assert(removeNested(scratch, parent, ["--fix", "alpha"], text) == 0);
    assert(text[1] == "");
    assert(buildPath(parent, ".gitrepos").readText == "");
    assert(buildPath(parent, ".gitignore").readText == ""); // the loose line moved into the block, then removed
}

/// Usage: no directory, an unknown option, --help; a malformed file changes nothing.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("removeNested-usage");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    string[2] text;
    assert(removeNested(scratch, scratch, [], text) == 2);
    assert(text[1].canFind("no nested directory given"));
    assert(removeNested(scratch, scratch, ["--nonsense", "alpha"], text) == 2);
    assert(removeNested(scratch, scratch, ["--help"], text) == 0);
    assert(text[0].canFind("Usage: remove-nested"));

    buildPath(scratch, ".gitrepos").write("/alpha/\n");
    assert(removeNested(scratch, scratch, ["alpha"], text) == 2);
    assert(text[1].canFind(".gitrepos: line 1: "));
    assert(buildPath(scratch, ".gitrepos").readText == "/alpha/\n");
}
