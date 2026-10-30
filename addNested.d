/**
 * add-nested: registers existing clones as nested repos of a parent
 * directory, in .gitrepos and in the managed block of .gitignore.
 *
 * Design: docs/nested-commands-proposal.md
 */
module addNested;

import std.stdio : File;

import gitRepos : GitRepos, GitReposEntry;
import nestedCommon : branchCanBeOmitted, CommonOptions, currentBranch, ExitStatus,
    loadParent, parseOptions, printFindings, remoteDefaultBranch, remoteHasBranch;
import parentDirectory : ParentDirectory;

enum usage = "Usage: add-nested [-C <directory>] [--fix] [--branch <name>] [--url <url>]
                  <nested directory>...
       add-nested [-C <directory>] [--fix] [--branch <name>]
                  --clone <url> [<nested directory>]

Registers each nested directory (an existing clone, given relative to the
parent directory) in .gitrepos and in the managed block of .gitignore.
Every argument is checked first; if any fails, nothing is written.
--branch and --url need exactly one nested directory.

With --clone, first clones <url> into the nested directory (by default
the name git clone would choose), which must not exist yet.

Exit status: 0 done, 1 an argument failed or problems remain, 2 bad usage
or a file that can't be read.
";

/**
 * Does all of add-nested's work; main() only calls this, so tests can run
 * it in-process with `output` and `errors` captured.
 *
 * Returns: the exit status.
 */
ExitStatus run(string[] args, File output, File errors)
{
    CommonOptions commonOptions;
    string branch, url, clone;
    const parsed = parseOptions(args, commonOptions, output, errors, usage,
        "branch", "Record this branch instead of the current one.", &branch,
        "url", "Record this url instead of the origin remote's.", &url,
        "clone", "Clone this url first, then register the clone.", &clone);
    if (!parsed.proceed)
    {
        return parsed.exitStatus;
    }
    immutable arguments = args[1 .. $].idup;
    if (clone.length)
    {
        return cloneAndAdd(commonOptions, clone, branch, url, arguments, output, errors);
    }
    if (arguments.length == 0)
    {
        errors.writeln("add-nested: no nested directory given");
        return ExitStatus.usage;
    }
    if ((branch.length || url.length) && arguments.length > 1)
    {
        errors.writeln("add-nested: --branch and --url need exactly one nested directory");
        return ExitStatus.usage;
    }

    ParentDirectory parentDirectory;
    if (!loadParent("add-nested", commonOptions.directory, parentDirectory, errors))
    {
        return ExitStatus.usage;
    }

    // All or nothing: work out every entry first, reporting every problem.
    GitReposEntry[] gitReposEntries;
    bool failed = false;
    foreach (argument; arguments)
    {
        GitReposEntry gitReposEntry;
        immutable problem = entryFor(commonOptions.directory, argument, branch, url, gitReposEntry);
        if (problem.length)
        {
            errors.writeln("add-nested: ", argument, ": ", problem);
            failed = true;
        }
        else
        {
            gitReposEntries ~= gitReposEntry;
        }
    }
    if (failed)
    {
        errors.writeln("add-nested: nothing was changed");
        return ExitStatus.findings;
    }

    if (commonOptions.fix)
    {
        parentDirectory.fix();
    }
    foreach (gitReposEntry; gitReposEntries)
    {
        parentDirectory.add(gitReposEntry);
    }
    try
    {
        parentDirectory.write();
    }
    catch (Exception exception)
    {
        errors.writeln("add-nested: could not write the files: ", exception.msg);
        return ExitStatus.findings;
    }
    foreach (gitReposEntry; gitReposEntries)
    {
        output.writeln("added ", gitReposEntry.directory, " ", gitReposEntry.url,
            gitReposEntry.branch.length ? " " ~ gitReposEntry.branch : "");
    }
    return checkWritten(commonOptions.directory, output, errors);
}

/**
 * The checks after writing, on the files as written, not the objects in
 * memory: add() appends, and only write() sorts, so the objects would look
 * unsorted. Returns: the exit status.
 * `parentDirectory` is a path, not a ParentDirectory, on purpose.
 */
ExitStatus checkWritten(string parentDirectory, File output, File errors)
{
    output.flush(); // before the warnings that follow on the error stream
    ParentDirectory written;
    if (!loadParent("add-nested", parentDirectory, written, errors))
    {
        return ExitStatus.findings;
    }
    immutable remaining = printFindings(written.check, errors);
    return remaining ? ExitStatus.findings : ExitStatus.ok;
}

/**
 * add-nested --clone <url> [<nested directory>]: everything is checked
 * before the network is used (the command line, both files, the target
 * directory), then the clone is made with nestedCommon.cloneNested (as
 * pull-nested makes them) and registered like an existing clone.
 *
 * Returns: the exit status.
 */
ExitStatus cloneAndAdd(CommonOptions commonOptions, string url, string branch, string urlOption,
    const string[] arguments, File output, File errors)
{
    import std.file : exists;
    import std.path : buildPath;
    import gitCloneDirectoryName : gitCloneDirectoryName, NoDirectoryNameException;
    import nestedCommon : cloneNested;

    if (urlOption.length)
    {
        errors.writeln("add-nested: --clone and --url can't be used together");
        return ExitStatus.usage;
    }
    if (arguments.length > 1)
    {
        errors.writeln("add-nested: --clone takes at most one nested directory");
        return ExitStatus.usage;
    }

    ParentDirectory parentDirectory;
    if (!loadParent("add-nested", commonOptions.directory, parentDirectory, errors))
    {
        return ExitStatus.usage;
    }

    string argument;
    if (arguments.length)
    {
        argument = arguments[0];
    }
    else
    {
        try
        {
            argument = gitCloneDirectoryName(url);
        }
        catch (NoDirectoryNameException)
        {
            errors.writeln("add-nested: can't guess a directory name from '", url,
                "'; give one after the url");
            return ExitStatus.findings;
        }
    }

    // The same directory rules as for an existing clone, before downloading.
    immutable directory = GitRepos.normalizeDirectory(argument);
    string invalid = directoryProblem(argument);
    if (invalid.length == 0)
    {
        auto planned = GitReposEntry(directory, url, branch);
        immutable problem = GitRepos.validate(planned);
        invalid = problem is null ? "" : problem;
    }
    if (invalid.length)
    {
        errors.writeln("add-nested: ", argument, ": ", invalid, "; nothing was cloned");
        return ExitStatus.findings;
    }
    immutable onDisk = buildPath(commonOptions.directory, directory[1 .. $ - 1]);
    if (onDisk.exists)
    {
        errors.writeln("add-nested: ", onDisk, " already exists; nothing was cloned"
            ~ " (to register an existing clone, leave out --clone)");
        return ExitStatus.findings;
    }

    immutable failure = cloneNested(onDisk, directory, url, branch, output, errors);
    if (failure.length)
    {
        output.flush();
        errors.writeln("add-nested: ", directory, ": ", failure,
            onDisk.exists ? "; the clone is kept but not registered (add-nested "
                ~ argument ~ " registers it once it's sorted out)" : "");
        return ExitStatus.findings;
    }

    // Registered like an existing clone; the url recorded is what git
    // stored, which for her ssh urls is exactly what she typed.
    GitReposEntry gitReposEntry;
    immutable problem = entryFor(commonOptions.directory, argument, branch, "", gitReposEntry);
    if (problem.length)
    {
        errors.writeln("add-nested: ", argument, ": cloned, but ", problem,
            "; not registered");
        return ExitStatus.findings;
    }
    if (commonOptions.fix)
    {
        parentDirectory.fix();
    }
    parentDirectory.add(gitReposEntry);
    try
    {
        parentDirectory.write();
    }
    catch (Exception exception)
    {
        errors.writeln("add-nested: cloned ", onDisk, ", but could not write the files: ",
            exception.msg, " (the clone is kept; add-nested ", argument, " registers it)");
        return ExitStatus.findings;
    }
    output.writeln("added ", gitReposEntry.directory, " ", gitReposEntry.url,
        gitReposEntry.branch.length ? " " ~ gitReposEntry.branch : "");
    return checkWritten(commonOptions.directory, output, errors);
}

/**
 * The rules for a nested directory argument that don't need the disk: no
 * "//" (checked before normalizing, which would strip it), something left
 * after normalizing, and no "." or ".." component. Returns: "" or why not.
 */
string directoryProblem(string argument)
{
    import std.algorithm.searching : canFind;
    import std.array : split;

    if (argument.canFind("//"))
    {
        return "too many slashes in directory '" ~ argument ~ "'";
    }
    immutable directory = GitRepos.normalizeDirectory(argument);
    if (directory.length == 0)
    {
        return "not a nested directory";
    }
    if (directory[1 .. $ - 1].split("/").canFind!(component => component == "." || component == ".."))
    {
        return "'.' and '..' are not allowed; give the directory relative to the parent";
    }
    return "";
}

/**
 * Works out the .gitrepos entry for `argument`, a nested directory relative
 * to `parentDirectory`. `branch` and `url` are the --branch and --url
 * values ("" when not given).
 * `parentDirectory` is a path, not a ParentDirectory, on purpose.
 *
 * Returns: "" and the entry in `gitReposEntry`, or why there can't be one.
 */
string entryFor(string parentDirectory, string argument, string branch, string url,
    out GitReposEntry gitReposEntry)
{
    import std.path : buildPath;

    immutable notDirectory = directoryProblem(argument);
    if (notDirectory.length)
    {
        return notDirectory;
    }
    immutable directory = GitRepos.normalizeDirectory(argument);

    immutable onDisk = buildPath(parentDirectory, directory[1 .. $ - 1]);
    immutable notRepository = ParentDirectory.repositoryProblem(directory, onDisk);
    if (notRepository.length)
    {
        return notRepository;
    }

    immutable origin = originUrl(onDisk);
    immutable recordedUrl = url.length ? url : origin;
    if (recordedUrl.length == 0)
    {
        return "it has no origin remote; give --url";
    }

    immutable current = currentBranch(onDisk);
    string recordedBranch = branch;
    if (recordedBranch.length == 0)
    {
        if (current.length == 0)
        {
            return "it has no current branch (detached HEAD); give --branch";
        }
        // origin/HEAD only describes origin, so it is unknown for another url.
        immutable remoteDefault = recordedUrl == origin ? remoteDefaultBranch(onDisk) : "";
        immutable omit = branchCanBeOmitted(directory, recordedUrl, current,
            (string candidate) => recordedUrl == origin && remoteHasBranch(onDisk, candidate), remoteDefault);
        recordedBranch = omit ? "" : current;
    }

    gitReposEntry = GitReposEntry(directory, recordedUrl, recordedBranch);
    immutable invalid = GitRepos.validate(gitReposEntry);
    return invalid is null ? "" : invalid;
}

/// The stored url of the repository's origin remote (`remote.origin.url`,
/// before any insteadOf rewriting), or "" if there is none.
string originUrl(string repository)
{
    import std.process : execute;
    import std.string : strip;

    const result = execute(["git", "-C", repository, "config", "--get", "remote.origin.url"]);
    return result.status == 0 ? result.output.strip : "";
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

    /// Runs add-nested on `parent` with `arguments`; returns the exit status,
    /// and what went to output and errors.
    private int addNested(string scratch, string parent, string[] arguments, out string[2] text)
    {
        int status;
        text = captured(scratch, (File output, File errors) {
            status = run(["add-nested", "-C", parent] ~ arguments, output, errors);
        });
        return status;
    }

    /// A bare remote `<name>.git` in `scratch` with branches `branches` (the
    /// first is its default) and one commit; returns its path.
    private string makeRemote(string scratch, string name, string[] branches...)
    {
        immutable remote = buildPath(scratch, name ~ ".git");
        immutable seed = buildPath(scratch, name ~ "-seed");
        git("init", "-q", "--bare", "-b", branches[0], remote);
        git("init", "-q", "-b", branches[0], seed);
        git("-C", seed, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
            "--allow-empty", "-m", "init");
        foreach (branch; branches)
        {
            git("-C", seed, "push", "-q", remote, branches[0] ~ ":" ~ branch);
        }
        return remote;
    }

    /// The text of the parent's .gitrepos and .gitignore ("" if missing).
    private string[2] files(string parent)
    {
        string read(string name)
        {
            immutable path = buildPath(parent, name);
            return path.exists ? path.readText : "";
        }
        return [read(".gitrepos"), read(".gitignore")];
    }
}

/// A clone on its remote's default branch: registered, branch left out.
/// The relative path that #8 broke works, and .gitignore gets /alpha/.
unittest
{
    immutable scratch = testDirectory("addNested-default");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", remote, buildPath(parent, "alpha"));

    string[2] text;
    assert(addNested(scratch, parent, ["alpha"], text) == 0, text[1]);
    assert(text[0] == "added /alpha/ " ~ remote ~ "\n" && text[1] == "");
    assert(files(parent) == ["/alpha/ " ~ remote ~ "\n",
        beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n"]);
}

/// On another branch: the branch is recorded. Adding again after switching
/// updates the entry (#10).
unittest
{
    immutable scratch = testDirectory("addNested-branch");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main", "dev");
    immutable parent = buildPath(scratch, "parent");
    immutable alpha = buildPath(parent, "alpha");
    git("clone", "-q", remote, alpha);
    git("-C", alpha, "checkout", "-q", "dev");

    string[2] text;
    assert(addNested(scratch, parent, ["/alpha/"], text) == 0, text[1]);
    assert(files(parent)[0] == "/alpha/ " ~ remote ~ " dev\n");

    git("-C", alpha, "checkout", "-q", "main");
    assert(addNested(scratch, parent, ["alpha/"], text) == 0, text[1]);
    assert(files(parent)[0] == "/alpha/ " ~ remote ~ "\n");
}

/// Directory named differently from the clone name (#2's shape).
unittest
{
    immutable scratch = testDirectory("addNested-names-differ");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "blog-bootstrap", "master", "blog");
    immutable parent = buildPath(scratch, "parent");
    immutable blog = buildPath(parent, "blog");
    git("clone", "-q", remote, blog);

    // On master (the default): recorded, so the line can't change meaning.
    string[2] text;
    assert(addNested(scratch, parent, ["blog"], text) == 0, text[1]);
    assert(files(parent)[0] == "/blog/ " ~ remote ~ " master\n");

    // On the branch named after the directory: left out.
    git("-C", blog, "checkout", "-q", "blog");
    assert(addNested(scratch, parent, ["blog"], text) == 0, text[1]);
    assert(files(parent)[0] == "/blog/ " ~ remote ~ "\n");
}

/// No origin/HEAD (init + remote add): the default is unknown, so recorded.
unittest
{
    immutable scratch = testDirectory("addNested-no-origin-head");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    immutable alpha = buildPath(parent, "alpha");
    git("init", "-q", "-b", "main", alpha);
    git("-C", alpha, "remote", "add", "origin", remote);

    string[2] text;
    assert(addNested(scratch, parent, ["alpha"], text) == 0, text[1]);
    assert(files(parent)[0] == "/alpha/ " ~ remote ~ " main\n");
}

/// Adding a directory that sorts before an existing one gives no false
/// "not sorted" warning: the files are checked as written.
unittest
{
    immutable scratch = testDirectory("addNested-sorts-first");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable alphaRemote = makeRemote(scratch, "alpha", "main");
    immutable betaRemote = makeRemote(scratch, "beta", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", alphaRemote, buildPath(parent, "alpha"));
    git("clone", "-q", betaRemote, buildPath(parent, "beta"));

    string[2] text;
    assert(addNested(scratch, parent, ["beta"], text) == 0, text[1]);
    assert(addNested(scratch, parent, ["alpha"], text) == 0, text[1]);
    assert(text[1] == "");
    assert(files(parent)[0] == "/alpha/ " ~ alphaRemote ~ "\n/beta/ " ~ betaRemote ~ "\n");
}

/// Several at once, all processed (#9).
unittest
{
    immutable scratch = testDirectory("addNested-several");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable alphaRemote = makeRemote(scratch, "alpha", "main");
    immutable betaRemote = makeRemote(scratch, "beta", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", alphaRemote, buildPath(parent, "alpha"));
    git("clone", "-q", betaRemote, buildPath(parent, "tools", "beta"));

    string[2] text;
    assert(addNested(scratch, parent, ["alpha", "tools/beta"], text) == 0, text[1]);
    assert(files(parent) == ["/alpha/ " ~ alphaRemote ~ "\n/tools/beta/ " ~ betaRemote ~ "\n",
        beginMarker ~ "\n/alpha/\n/tools/beta/\n" ~ endMarker ~ "\n"]);
}

/// All or nothing: one bad argument means nothing is written, and every
/// problem is reported.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("addNested-all-or-nothing");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable alphaRemote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", alphaRemote, buildPath(parent, "alpha"));
    buildPath(parent, "plain").mkdirRecurse;                          // not a repository
    git("init", "-q", buildPath(parent, "lonely"));                   // no origin remote
    git("clone", "-q", alphaRemote, buildPath(parent, "detached"));
    git("-C", buildPath(parent, "detached"), "checkout", "-q", "--detach");

    string[2] text;
    assert(addNested(scratch, parent,
        ["alpha", "missing", "plain", "lonely", "detached", "../alpha", "//alpha"], text) == 1);
    assert(text[0] == "");
    assert(text[1].canFind("missing: /missing/ does not exist"));
    assert(text[1].canFind("plain: /plain/ is not a git repository"));
    assert(text[1].canFind("lonely: it has no origin remote; give --url"));
    assert(text[1].canFind("detached: it has no current branch (detached HEAD); give --branch"));
    assert(text[1].canFind("../alpha: '.' and '..' are not allowed"));
    assert(text[1].canFind("//alpha: too many slashes in directory"));
    assert(text[1].canFind("nothing was changed"));
    assert(files(parent) == ["", ""]); // alpha, though fine, wasn't added either
}

/// --url and --branch override, and need exactly one directory.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("addNested-overrides");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable parent = buildPath(scratch, "parent");
    immutable lonely = buildPath(parent, "lonely");
    git("init", "-q", "-b", "main", lonely);
    git("-C", lonely, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
        "--allow-empty", "-m", "x");

    string[2] text;
    assert(addNested(scratch, parent,
        ["--url", "git@github.com:pflagerd/lonely.git", "--branch", "release", "lonely"], text) == 0,
        text[1]);
    assert(files(parent)[0] == "/lonely/ git@github.com:pflagerd/lonely.git release\n");

    assert(addNested(scratch, parent, ["--branch", "x", "lonely", "other"], text) == 2);
    assert(text[1].canFind("need exactly one nested directory"));
}

/// --fix repairs the files too; remaining problems are reported (exit 1).
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("addNested-fix");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable alphaRemote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", alphaRemote, buildPath(parent, "alpha"));
    parent.mkdirRecurse;
    buildPath(parent, ".gitignore").write("gamma\n"); // a loose line for /gamma/
    buildPath(parent, ".gitrepos").write("/gamma/ g.git\n");

    string[2] text;
    assert(addNested(scratch, parent, ["alpha"], text) == 1);
    assert(text[1].canFind("outside the managed block"));

    assert(addNested(scratch, parent, ["--fix", "alpha"], text) == 0, text[1]);
    assert(files(parent)[1] == beginMarker ~ "\n/alpha/\n/gamma/\n" ~ endMarker ~ "\n");
}

/// Usage: no directory, an unknown option, --help; a malformed file changes nothing.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("addNested-usage");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    string[2] text;
    assert(addNested(scratch, scratch, [], text) == 2);
    assert(text[1].canFind("no nested directory given"));
    assert(addNested(scratch, scratch, ["--nonsense", "alpha"], text) == 2);
    assert(addNested(scratch, scratch, ["--help"], text) == 0);
    assert(text[0].canFind("Usage: add-nested"));

    buildPath(scratch, ".gitrepos").write("/alpha/\n");
    assert(addNested(scratch, scratch, ["alpha"], text) == 2);
    assert(buildPath(scratch, ".gitrepos").readText == "/alpha/\n");
}

// --- tests: --clone ----------------------------------------------------------------

/// --clone with no directory: the name git clone would choose; default branch
/// left out.
unittest
{
    immutable scratch = testDirectory("addNested-clone");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main", "dev");
    immutable parent = buildPath(scratch, "parent");
    parent.mkdirRecurse;

    string[2] text;
    assert(addNested(scratch, parent, ["--clone", remote], text) == 0, text[1]);
    assert(currentBranch(buildPath(parent, "alpha")) == "main");
    assert(files(parent) == ["/alpha/ " ~ remote ~ "\n",
        beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n"]);
    assert(text[0] == "added /alpha/ " ~ remote ~ "\n");
}

/// --clone into a named directory with --branch (#2's shape), and the
/// directory-name rule without --branch.
unittest
{
    immutable scratch = testDirectory("addNested-clone-named");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "blog-bootstrap", "master", "bok-blog", "blog");
    immutable parent = buildPath(scratch, "parent");
    parent.mkdirRecurse;

    string[2] text;
    assert(addNested(scratch, parent, ["--branch", "bok-blog", "--clone", remote, "site"], text) == 0,
        text[1]);
    assert(currentBranch(buildPath(parent, "site")) == "bok-blog");
    assert(files(parent)[0] == "/site/ " ~ remote ~ " bok-blog\n");

    // No --branch: the remote has a branch named after the directory, so the
    // clone is on it and the branch is left out.
    assert(addNested(scratch, parent, ["--clone", remote, "blog"], text) == 0, text[1]);
    assert(currentBranch(buildPath(parent, "blog")) == "blog");
    assert(files(parent)[0] == "/blog/ " ~ remote ~ "\n/site/ " ~ remote ~ " bok-blog\n");
}

/// Everything is checked before the network is used: nothing is cloned.
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : dirEntries, SpanMode;
    import std.algorithm.searching : count;

    immutable scratch = testDirectory("addNested-clone-checks");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    buildPath(parent, "taken").mkdirRecurse;

    string[2] text;
    assert(addNested(scratch, parent, ["--clone", remote, "taken"], text) == 1);
    assert(text[1].canFind("already exists; nothing was cloned"));
    assert(addNested(scratch, parent, ["--clone", remote, "../outside"], text) == 1);
    assert(text[1].canFind("'.' and '..' are not allowed") && text[1].canFind("nothing was cloned"));
    assert(addNested(scratch, parent, ["--clone", remote, "//alpha"], text) == 1);
    assert(addNested(scratch, parent, ["--branch", "a//b", "--clone", remote], text) == 1);
    assert(text[1].canFind("too many slashes in branch"));

    // A malformed .gitrepos stops it too, before cloning.
    buildPath(parent, ".gitrepos").write("/x/\n");
    assert(addNested(scratch, parent, ["--clone", remote], text) == 2);
    buildPath(parent, ".gitrepos").write("");

    assert(dirEntries(parent, SpanMode.shallow).count == 2); // taken/ and .gitrepos only
    assert(files(parent) == ["", ""]);
}

/// A failed clone leaves nothing; a failed checkout keeps the clone, unregistered.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("addNested-clone-failures");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    parent.mkdirRecurse;

    string[2] text;
    assert(addNested(scratch, parent, ["--clone", buildPath(scratch, "nope.git"), "gone"], text) == 1);
    assert(text[1].canFind("git clone failed") && !buildPath(parent, "gone").exists);

    assert(addNested(scratch, parent, ["--branch", "missing", "--clone", remote], text) == 1);
    assert(text[1].canFind("could not check out branch 'missing'")
        && text[1].canFind("the clone is kept but not registered"));
    assert(buildPath(parent, "alpha").exists);
    assert(files(parent) == ["", ""]);
}

/// Command-line mistakes with --clone are usage errors.
unittest
{
    import std.algorithm.searching : canFind;

    immutable scratch = testDirectory("addNested-clone-usage");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    string[2] text;
    assert(addNested(scratch, scratch, ["--clone", "x.git", "a", "b"], text) == 2);
    assert(text[1].canFind("at most one nested directory"));
    assert(addNested(scratch, scratch, ["--clone", "x.git", "--url", "y.git"], text) == 2);
    assert(text[1].canFind("--clone and --url"));
}
