/**
 * add-nested: registers existing clones as nested repos of a parent
 * directory, in .gitrepos and in the managed block of .gitignore.
 *
 * Design: docs/nested-commands-proposal.md
 */
module addNested;

import std.stdio : File;

import gitRepos : GitRepos, GitReposEntry;
import nestedCommand : branchCanBeOmitted, CommonOptions, currentBranch, ExitStatus,
    loadParent, parseOptions, printFindings, remoteDefaultBranch, remoteHasBranch;
import parentDirectory : ParentDirectory;

enum usage = "Usage: add-nested [-C <directory>] [--fix] [--branch <name>] [--url <url>]
                  <nested directory>...

Registers each nested directory (an existing clone, given relative to the
parent directory) in .gitrepos and in the managed block of .gitignore.
Every argument is checked first; if any fails, nothing is written.
--branch and --url need exactly one nested directory. Exit status: 0 done,
1 an argument failed or problems remain, 2 bad usage or a file that can't
be read.
";

/**
 * Does all of add-nested's work; main() only calls this, so tests can run
 * it in-process with `output` and `errors` captured.
 *
 * Returns: the exit status.
 */
int run(string[] args, File output, File errors)
{
    CommonOptions common;
    string branch, url;
    const parsed = parseOptions(args, common, output, errors, usage,
        "branch", "Record this branch instead of the current one.", &branch,
        "url", "Record this url instead of the origin remote's.", &url);
    if (!parsed.proceed)
    {
        return parsed.exitStatus;
    }
    immutable arguments = args[1 .. $].idup;
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

    ParentDirectory parent;
    if (!loadParent("add-nested", common.directory, parent, errors))
    {
        return ExitStatus.usage;
    }

    // All or nothing: work out every entry first, reporting every problem.
    GitReposEntry[] entries;
    bool failed = false;
    foreach (argument; arguments)
    {
        GitReposEntry entry;
        immutable problem = entryFor(common.directory, argument, branch, url, entry);
        if (problem.length)
        {
            errors.writeln("add-nested: ", argument, ": ", problem);
            failed = true;
        }
        else
        {
            entries ~= entry;
        }
    }
    if (failed)
    {
        errors.writeln("add-nested: nothing was changed");
        return ExitStatus.findings;
    }

    if (common.fix)
    {
        parent.fix();
    }
    foreach (entry; entries)
    {
        parent.add(entry);
    }
    try
    {
        parent.write();
    }
    catch (Exception e)
    {
        errors.writeln("add-nested: could not write the files: ", e.msg);
        return ExitStatus.findings;
    }
    foreach (entry; entries)
    {
        output.writeln("added ", entry.directory, " ", entry.url,
            entry.branch.length ? " " ~ entry.branch : "");
    }
    output.flush(); // before the warnings that follow on the error stream

    // Check the files as written, not the objects in memory: add() appends,
    // and only write() sorts, so the objects would look unsorted.
    ParentDirectory written;
    if (!loadParent("add-nested", common.directory, written, errors))
    {
        return ExitStatus.findings;
    }
    immutable remaining = printFindings(written.check, errors);
    return remaining ? ExitStatus.findings : ExitStatus.ok;
}

/**
 * Works out the .gitrepos entry for `argument`, a nested directory relative
 * to `parentDirectory`. `branch` and `url` are the --branch and --url
 * values ("" when not given).
 *
 * Returns: "" and the entry in `entry`, or why there can't be one.
 */
string entryFor(string parentDirectory, string argument, string branch, string url,
    out GitReposEntry entry)
{
    import std.algorithm.searching : canFind;
    import std.array : split;
    import std.path : buildPath;

    // Checked before normalizing, which would strip the extra slashes.
    if (argument.canFind("//"))
    {
        return "too many slashes in directory '" ~ argument ~ "'";
    }
    immutable directory = GitRepos.normalizeDirectory(argument);
    if (directory.length == 0)
    {
        return "not a nested directory";
    }
    if (directory[1 .. $ - 1].split("/").canFind!(c => c == "." || c == ".."))
    {
        return "'.' and '..' are not allowed; give the directory relative to the parent";
    }

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
            (string b) => recordedUrl == origin && remoteHasBranch(onDisk, b), remoteDefault);
        recordedBranch = omit ? "" : current;
    }

    entry = GitReposEntry(directory, recordedUrl, recordedBranch);
    immutable invalid = GitRepos.validate(entry);
    return invalid is null ? "" : invalid;
}

/// The stored url of the repository's origin remote (`remote.origin.url`,
/// before any insteadOf rewriting), or "" if there is none.
string originUrl(string repository)
{
    import std.process : execute;
    import std.string : strip;

    const r = execute(["git", "-C", repository, "config", "--get", "remote.origin.url"]);
    return r.status == 0 ? r.output.strip : "";
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
        foreach (b; branches)
        {
            git("-C", seed, "push", "-q", remote, branches[0] ~ ":" ~ b);
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

    immutable a = makeRemote(scratch, "alpha", "main");
    immutable b = makeRemote(scratch, "beta", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", a, buildPath(parent, "alpha"));
    git("clone", "-q", b, buildPath(parent, "beta"));

    string[2] text;
    assert(addNested(scratch, parent, ["beta"], text) == 0, text[1]);
    assert(addNested(scratch, parent, ["alpha"], text) == 0, text[1]);
    assert(text[1] == "");
    assert(files(parent)[0] == "/alpha/ " ~ a ~ "\n/beta/ " ~ b ~ "\n");
}

/// Several at once, all processed (#9).
unittest
{
    immutable scratch = testDirectory("addNested-several");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable a = makeRemote(scratch, "alpha", "main");
    immutable b = makeRemote(scratch, "beta", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", a, buildPath(parent, "alpha"));
    git("clone", "-q", b, buildPath(parent, "tools", "beta"));

    string[2] text;
    assert(addNested(scratch, parent, ["alpha", "tools/beta"], text) == 0, text[1]);
    assert(files(parent) == ["/alpha/ " ~ a ~ "\n/tools/beta/ " ~ b ~ "\n",
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

    immutable a = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", a, buildPath(parent, "alpha"));
    buildPath(parent, "plain").mkdirRecurse;                          // not a repository
    git("init", "-q", buildPath(parent, "lonely"));                   // no origin remote
    git("clone", "-q", a, buildPath(parent, "detached"));
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

    immutable a = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", a, buildPath(parent, "alpha"));
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
