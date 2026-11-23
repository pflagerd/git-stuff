/**
 * remove-nested: unregisters nested repos from a parent directory's
 * .gitrepos and .gitignore. It never deletes a directory.
 *
 * Design: docs/nested-commands-proposal.md
 */
module removeNested;

import std.stdio : File;
import std.typecons : No;

import nestedCommon : ChecksOutcome, CommonOptions, ExitStatus, loadParent, parseOptions, runChecks,
    warnForceWithoutRecursive;
import parentDirectory : ParentDirectory;

enum usage = "Usage: remove-nested [-C <directory>] [-r [-f]] [--fix | --no-check]
                     <nested directory>...

Removes each nested directory from .gitrepos and from the managed block of
.gitignore. The directory itself is never touched. First, check-nested's
checks run on the whole directory and report what they find, with -r, -f
and --fix as in check-nested, except that --fix doesn't register unlisted
repos. --no-check skips them.

Exit status: 0 done, 1 something wasn't registered or problems remain
(with --no-check, only something not registered or a failed write), 2 bad
usage or a file that can't be read.
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

    CommonOptions commonOptions;
    const parsed = parseOptions(args, commonOptions, output, errors, usage);
    if (!parsed.proceed)
    {
        return parsed.exitStatus;
    }
    if (args.length < 2)
    {
        errors.writeln("remove-nested: no nested directory given");
        return ExitStatus.usage;
    }
    warnForceWithoutRecursive("remove-nested", commonOptions, errors);

    ParentDirectory parentDirectory;
    if (!loadParent("remove-nested", commonOptions.directory, parentDirectory, errors))
    {
        return ExitStatus.usage;
    }

    // The checks first, on the whole parent (#29 decisions 1 and 10, step
    // 3), so in this run the directories being removed are still listed.
    // --fix writes its repairs here, registering nothing, and the removal
    // below goes on from the fixed objects. --no-check skips the checks;
    // the exit status then reflects only the removal: a name that wasn't
    // registered, or a failed write.
    bool remaining = false;
    if (!commonOptions.noCheck)
    {
        const checksResult = runChecks(parentDirectory, commonOptions, No.register, output, errors);
        with (ChecksOutcome) final switch (checksResult.outcome)
        {
        case clean:
            break;
        case findingsRemain:
            remaining = true;
            break;
        case writeFailed:
            errors.writeln("remove-nested: ", checksResult.message);
            return ExitStatus.findings; // nothing was removed
        }
    }

    bool changed = false;
    bool notFound = false;
    foreach (argument; args[1 .. $])
    {
        immutable directory = GitRepos.normalizeDirectory(argument);
        immutable inRepos = parentDirectory.gitRepos.gitReposEntries.any!(gitReposEntry => gitReposEntry.directory == directory);
        immutable inIgnore = parentDirectory.gitIgnore.nested.canFind(directory);

        if (directory.length == 0 || !parentDirectory.remove(directory))
        {
            errors.writeln("warning: ", argument, " is in neither ", parentDirectory.gitRepos.path,
                " nor the managed block of ", parentDirectory.gitIgnore.path);
            notFound = true;
            continue;
        }
        changed = true;

        immutable from = inRepos && inIgnore ? ".gitrepos and .gitignore"
            : inRepos ? ".gitrepos" : ".gitignore";
        immutable onDisk = buildPath(commonOptions.directory, directory[1 .. $ - 1]);
        output.writeln("removed ", directory, " from ", from,
            onDisk.exists ? "; " ~ onDisk ~ " is still on disk (remove-nested never deletes directories)"
                : "");
    }

    if (changed)
    {
        try
        {
            parentDirectory.write();
        }
        catch (Exception exception)
        {
            errors.writeln("remove-nested: could not write the files: ", exception.msg);
            return ExitStatus.findings;
        }
    }
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
    import nestedCommon : captured, missingOnly;
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
    /// Neither is on disk, so since #29 step 3 the checks before the
    /// removal report both as missing (see missingOnly), and the exit
    /// status is 1.
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
    assert(removeNested(scratch, parent, ["alpha"], text) == 1); // see twoRepos
    assert(text[0] == "removed /alpha/ from .gitrepos and .gitignore\n");
    assert(missingOnly(parent, text[1], "alpha", "beta"), text[1]);
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
    assert(removeNested(scratch, parent, ["/alpha/", "beta/"], text) == 1); // see twoRepos
    assert(missingOnly(parent, text[1], "alpha", "beta"), text[1]);
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
    // The checks report alpha (not a git repository) and beta (missing).
    assert(removeNested(scratch, parent, ["alpha"], text) == 1, text[1]);
    assert(text[1].canFind("/alpha/ is not a git repository"), text[1]);
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
    assert(removeNested(scratch, parent, ["alpha"], text) == 1); // see twoRepos
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
    // The checks, before the removal, report what the removal then
    // resolves: /beta/ is missing on disk and from the block, /alpha/ is in
    // the block but not in .gitrepos. So this exits 1 where it exited 0
    // (#29 step 3; step 5 leaves such findings out).
    assert(removeNested(scratch, parent, ["alpha", "beta"], text) == 1);
    assert(text[0] == "removed /alpha/ from .gitignore\nremoved /beta/ from .gitrepos\n");
}

/// Problems are reported before removing (#29 step 3); --fix repairs them
/// first.
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

    // What's left after --fix: /alpha/, the one being removed, is missing.
    assert(removeNested(scratch, parent, ["--fix", "alpha"], text) == 1);
    assert(text[0] == "fixed 1 problem(s)\nremoved /alpha/ from .gitrepos and .gitignore\n", text[0]);
    assert(missingOnly(parent, text[1], "alpha"), text[1]);
    assert(buildPath(parent, ".gitrepos").readText == "");
    assert(buildPath(parent, ".gitignore").readText == ""); // the loose line moved into the block, then removed
}

/// --fix doesn't register an unlisted nested repo: only check-nested --fix
/// does that (#15; #29 step 3). It is reported instead.
unittest
{
    import std.algorithm.searching : canFind;
    import nestedCommon : git, makeRemote;

    immutable scratch = testDirectory("removeNested-fix-unlisted");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = twoRepos(scratch);
    immutable remote = makeRemote(scratch, "gamma", "main");
    git("clone", "-q", "-b", "main", remote, buildPath(parent, "gamma")); // unlisted, fixable
    git("-C", buildPath(parent, "gamma"), "remote", "set-head", "origin", "main");

    string[2] text;
    assert(removeNested(scratch, parent, ["--fix", "alpha"], text) == 1); // see twoRepos
    assert(text[1].canFind("/gamma/ is a git repository but is not listed"), text[1]);
    assert(!text[0].canFind("added"), text[0]);
    assert(buildPath(parent, ".gitrepos").readText == "/beta/ b.git dev\n");
    assert(buildPath(parent, ".gitignore").readText
        == "*.o\n" ~ beginMarker ~ "\n/beta/\n" ~ endMarker ~ "\n");
}

/// --no-check (#29): the removal happens, nothing is reported about the
/// files afterwards, and the exit status reflects only the removal; a name
/// that isn't registered still exits 1. --no-check --fix is bad usage
/// (decision 12) and changes nothing.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("removeNested-no-check");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = twoRepos(scratch);
    immutable gitIgnorePath = buildPath(parent, ".gitignore");
    immutable gitReposPath = buildPath(parent, ".gitrepos");
    // /ghost/ is in the block but not in .gitrepos: a finding --fix can't repair.
    gitIgnorePath.write("*.o\n" ~ beginMarker ~ "\n/alpha/\n/beta/\n/ghost/\n" ~ endMarker ~ "\n");

    string[2] text;
    foreach (given; [["--no-check", "--fix"], ["--fix", "--no-check"]])
    {
        assert(removeNested(scratch, parent, given ~ "alpha", text) == 2, given[0]);
        assert(text[1] == "remove-nested: --no-check can't be used with --fix: with the checks off,"
            ~ " there is nothing for it to do\n", text[1]);
        assert(text[0] == "");
        assert(gitReposPath.readText == "/alpha/ a.git\n/beta/ b.git dev\n"); // untouched
    }

    assert(removeNested(scratch, parent, ["--no-check", "alpha"], text) == 0, text[1]);
    assert(text[0] == "removed /alpha/ from .gitrepos and .gitignore\n" && text[1] == "", text[1]);
    assert(gitReposPath.readText == "/beta/ b.git dev\n");
    assert(gitIgnorePath.readText == "*.o\n" ~ beginMarker ~ "\n/beta/\n/ghost/\n" ~ endMarker ~ "\n");

    // Without --no-check the same parent is reported, as before.
    assert(removeNested(scratch, parent, ["beta"], text) == 1);
    assert(text[1].canFind("warning: ") && text[1].canFind("/ghost/ is in the managed block"), text[1]);

    // A name that isn't registered is the removal's own failure: still 1.
    assert(removeNested(scratch, parent, ["--no-check", "delta"], text) == 1);
    assert(text[1].canFind("delta is in neither") && !text[1].canFind("/ghost/"), text[1]);
}

/// The checks run first, on the whole parent, with check-nested's options
/// (#29 decisions 1 and 10, step 3): the report comes before the `removed`
/// line, and the directory being removed is still listed in it; -r and -f
/// reach it; --fix writes its repair first and registers nothing; -f
/// without -r gets the warning; --no-check with -f is bad usage.
unittest
{
    import std.algorithm.searching : canFind;
    import nestedCommon : capturedTogether, checksFixture, comesBefore;

    immutable scratch = testDirectory("removeNested-checks-first");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = checksFixture(scratch);
    immutable gitReposPath = buildPath(parent, ".gitrepos");
    immutable gitIgnorePath = buildPath(parent, ".gitignore");
    immutable listing = gitReposPath.readText;
    immutable ignoring = gitIgnorePath.readText;
    string together(string[] arguments...)
    {
        return capturedTogether(scratch, (File output, File errors) {
            run(["remove-nested", "-C", parent] ~ arguments, output, errors);
        });
    }

    string[2] text;
    assert(removeNested(scratch, parent, ["--no-check", "-f", "alpha"], text) == 2);
    assert(text[0] == "" && text[1].canFind("--no-check can't be used with -f/--force"), text[1]);
    assert(gitReposPath.readText == listing && gitIgnorePath.readText == ignoring);

    // -f alone: the warning, then the removal; nothing else to report.
    immutable noEffect = "remove-nested: warning: -f/--force has no effect without -r/--recursive\n";
    immutable removed = "removed /alpha/ from .gitrepos and .gitignore";
    immutable warned = together("-f", "alpha");
    assert(comesBefore(warned, noEffect, removed), warned);
    assert(!warned.canFind("warning: /"), warned);

    // --fix -r -f: the repair is written first, both unlisted repos are
    // reported before the removal, alpha isn't (it is still listed), and
    // nothing is registered.
    gitReposPath.write(listing);
    gitIgnorePath.write("/private/\n"); // /alpha/ not in the block
    immutable gamma = "warning: " ~ buildPath(parent, "tools", "gamma") ~ ": /tools/gamma/ is a git repository";
    immutable secret = "/private/secret/ is a git repository";
    immutable fixed = together("--fix", "-r", "-f", "alpha");
    assert(comesBefore(fixed, "fixed 1 problem(s)\n", gamma), fixed);
    assert(comesBefore(fixed, gamma, removed) && comesBefore(fixed, secret, removed), fixed);
    assert(!fixed.canFind("/alpha/ is a git repository") && !fixed.canFind("added "), fixed);
    assert(gitReposPath.readText == "");
    assert(gitIgnorePath.readText == "/private/\n");
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
