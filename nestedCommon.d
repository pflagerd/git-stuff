/**
 * What the nested-repo commands (check-nested, add-nested, remove-nested,
 * pull-nested, push-nested) share: exit statuses, option parsing, printing findings,
 * running the checks (runChecks), the branch rules, a few git queries, and
 * working out the .gitrepos entry for an existing clone (entryFor).
 *
 * Design: docs/nested-commands-proposal.md
 */
module nestedCommon;

import core.attribute : mustuse;
import std.stdio : File;

import finding : Finding;
import gitRepos : GitRepos, GitReposEntry, ValidationOutcome;
import parentDirectory : ParentDirectory, RepositoryOutcome;

/// Exit statuses, the same three-way convention as GNU grep.
enum ExitStatus : int
{
    ok = 0,       /// did its job, and no findings remain
    findings = 1, /// findings remain, or a git command failed for some repo
    usage = 2,    /// couldn't start: bad usage, or a file that won't parse
}

// --- options -------------------------------------------------------------------

/**
 * The options every command takes, and the check options runChecks()
 * reads. For now only check-nested parses `recursive` and `force`: it
 * passes them to parseOptions() among its own options (`extra`). In the
 * other commands they stay false (#29, step 2).
 */
struct CommonOptions
{
    string directory = "."; /// -C: the parent directory to work in
    bool fix;               /// --fix: repair fixable findings first
    bool noCheck;           /// --no-check: skip the checks and their report (#29)
    bool recursive;         /// -r/--recursive: look for unlisted repos below the direct subdirectories too
    bool force;             /// -f/--force: with -r, also look inside the directories .gitignore names
}

/**
 * The check options set in `commonOptions`, as she would type them. These
 * only change what the checks do, so --no-check leaves them nothing to do
 * (#29, decision 12). A new common check option, such as -f/--force
 * (#15 step 4), gets a line here and is then refused with --no-check by
 * every command.
 */
string[] checkOptionsGiven(const CommonOptions commonOptions) @safe pure nothrow
{
    string[] given;
    if (commonOptions.fix)
    {
        given ~= "--fix";
    }
    return given;
}

/**
 * The usage error for --no-check together with check options (#29,
 * decision 12): prints one line to `errors` naming them, prefixed with
 * `program`. Does nothing when `checkOptions` is empty.
 *
 * Returns: true if it printed the error, so the caller exits with
 * ExitStatus.usage.
 */
bool reportNoCheckConflict(string program, const string[] checkOptions, File errors)
{
    import std.array : join;

    if (checkOptions.length == 0)
    {
        return false;
    }
    errors.writeln(program, ": --no-check can't be used with ", checkOptions.join(", "),
        ": with the checks off, there is nothing for ", checkOptions.length == 1 ? "it" : "them",
        " to do");
    return true;
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
     *   missing value), or --no-check with a check option such as --fix,
     *   and a message has been printed to the errors.
     *
     * It is never ExitStatus.findings (1). When `proceed` is true it is
     * left at ExitStatus.ok and callers ignore it. Being an ExitStatus, not
     * an int, it can only hold those values; it still converts to int, so
     * a run() can return it directly.
     */
    ExitStatus exitStatus;
}

/**
 * Parses -C, --fix, --no-check and -h/--help, plus any options of one command passed as
 * `extra` (in std.getopt's form: name, help text, pointer, ...). What is
 * left in `args` afterwards is the program name followed by the positional
 * arguments.
 *
 * -h/--help prints `usage` and the option list to `output` (exit 0). An
 * unknown or malformed option prints a message to `errors` (exit 2), and so
 * does --no-check with a common check option (reportNoCheckConflict). A
 * command's own check options, such as check-nested's -r, are its own to
 * refuse. Options are case-sensitive, so -C is not -c.
 */
Parsed parseOptions(Extra...)(ref string[] args, ref CommonOptions commonOptions,
    File output, File errors, string usage, Extra extra)
{
    import std.getopt : config, defaultGetoptFormatter, getopt, GetOptException;
    import std.conv : ConvException;

    try
    {
        auto result = getopt(args, config.caseSensitive,
            "C", "Work in <directory> instead of the current directory.", &commonOptions.directory,
            "fix", "Repair fixable findings in .gitignore and .gitrepos first.", &commonOptions.fix,
            "no-check", "Don't check .gitignore and .gitrepos or report their problems; not with --fix.",
                &commonOptions.noCheck,
            extra);
        if (result.helpWanted)
        {
            defaultGetoptFormatter(output.lockingTextWriter, usage, result.options);
            return Parsed(false, ExitStatus.ok);
        }
    }
    catch (GetOptException exception)
    {
        errors.writeln(args.length ? args[0] : "nested", ": ", exception.msg);
        return Parsed(false, ExitStatus.usage);
    }
    catch (ConvException exception) // e.g. a value of the wrong type
    {
        errors.writeln(args.length ? args[0] : "nested", ": ", exception.msg);
        return Parsed(false, ExitStatus.usage);
    }
    if (commonOptions.noCheck
        && reportNoCheckConflict(args.length ? args[0] : "nested", checkOptionsGiven(commonOptions), errors))
    {
        return Parsed(false, ExitStatus.usage);
    }
    return Parsed(true, ExitStatus.ok);
}

// --- loading ---------------------------------------------------------------------

/**
 * Loads the ParentDirectory for `directory` into `parentDirectory`. On failure prints
 * why to `errors`, prefixed with `program` and naming the file (and line,
 * for a parse error), and returns false: the caller exits with
 * ExitStatus.usage, having changed nothing.
 */
bool loadParent(string program, string directory, out ParentDirectory parentDirectory, File errors)
{
    import std.file : FileException;
    import std.path : buildPath;
    import std.utf : UTFException;
    import gitIgnore : GitIgnoreException;
    import gitRepos : GitReposException;

    try
    {
        parentDirectory = new ParentDirectory(directory);
        return true;
    }
    catch (GitIgnoreException exception)
    {
        errors.writeln(program, ": ", buildPath(directory, ".gitignore"), ": ", exception.msg);
    }
    catch (GitReposException exception)
    {
        errors.writeln(program, ": ", buildPath(directory, ".gitrepos"), ": ", exception.msg);
    }
    catch (UTFException exception)
    {
        errors.writeln(program, ": a file in ", directory, " is not valid UTF-8: ", exception.msg);
    }
    catch (FileException exception)
    {
        errors.writeln(program, ": ", exception.msg);
    }
    return false;
}

// --- the checks ------------------------------------------------------------------

/// What runChecks found.
enum ChecksOutcome
{
    clean,          /// nothing to report (after --fix, if given)
    findingsRemain, /// findings were printed to the errors
    writeFailed,    /// --fix couldn't write the fixed files; the findings weren't printed
}

/// runChecks's result: what happened, and a message for her to read.
/// Design: docs/result-types.md
@mustuse struct ChecksResult
{
    ChecksOutcome outcome;
    string message; /// "" unless outcome is writeFailed
}

/**
 * check-nested's work on a loaded `parentDirectory`, with the check
 * options in `commonOptions` (#29, step 2):
 *
 * 1. With --fix: registers the unlisted repos (registerUnlisted(), with
 *    -r and -f), then fix() and write(); then prints `added ...` for each
 *    repo it registered and `fixed N problem(s)` to `output`.
 * 2. Prints the findings left, check() ~ checkDisk(), to `errors`.
 *
 * It reads neither `commonOptions.noCheck` nor `commonOptions.directory`:
 * the caller has already dealt with --no-check, and loaded the parent.
 *
 * Returns: clean or findingsRemain; or writeFailed, with a message for the
 * caller to print after its program name. After writeFailed, step 2
 * hasn't run.
 */
ChecksResult runChecks(ParentDirectory parentDirectory, const CommonOptions commonOptions,
    File output, File errors)
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : count;
    import std.typecons : No, Yes;

    immutable recursive = commonOptions.recursive ? Yes.recursive : No.recursive;
    immutable force = commonOptions.force ? Yes.force : No.force;

    if (commonOptions.fix)
    {
        immutable fixable = parentDirectory.check.filter!(finding => finding.fixable).count;
        // Registered first, so fix() then sorts them into both files.
        const gitReposEntries = parentDirectory.registerUnlisted(recursive, force);
        parentDirectory.fix();
        try
        {
            parentDirectory.write();
        }
        catch (Exception exception)
        {
            return ChecksResult(ChecksOutcome.writeFailed,
                "could not write the fixed files: " ~ exception.msg);
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

    immutable remaining = printFindings(parentDirectory.check ~ parentDirectory.checkDisk(recursive, force),
        errors);
    if (remaining)
    {
        return ChecksResult(ChecksOutcome.findingsRemain, "");
    }
    return ChecksResult(ChecksOutcome.clean, "");
}

// --- output --------------------------------------------------------------------

/// Prints each finding to `errors` as "warning: <message>", noting the
/// fixable ones. Returns: how many were printed.
size_t printFindings(const Finding[] findings, File errors)
{
    foreach (finding; findings)
    {
        errors.writeln("warning: ", finding.message, finding.fixable ? " (fixable with --fix)" : "");
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
    import gitCloneDirectoryName : gitCloneDirectoryName, NoDirectoryNameException;

    try
    {
        return lastComponent(directory) != gitCloneDirectoryName(url);
    }
    catch (NoDirectoryNameException)
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

    const result = execute(["git", "-C", repository, "symbolic-ref", "--quiet", "--short", "HEAD"]);
    return result.status == 0 ? result.output.strip : "";
}

/// Whether the repository has `refs/remotes/origin/<branch>` locally.
bool remoteHasBranch(string repository, string branch)
{
    import std.process : execute;

    const result = execute(["git", "-C", repository, "rev-parse", "--verify", "--quiet",
        "refs/remotes/origin/" ~ branch]);
    return result.status == 0;
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

    const result = execute(["git", "-C", repository, "symbolic-ref", "--quiet", "--short",
        "refs/remotes/origin/HEAD"]);
    immutable name = result.output.strip;
    if (result.status != 0 || !name.startsWith("origin/"))
    {
        return "";
    }
    return name["origin/".length .. $];
}

// --- registering an existing clone ----------------------------------------------
// add-nested <dir> and check-nested --fix both work out an entry this way.

/// What checkDirectoryArgument found: valid, or the first rule broken.
enum DirectoryArgumentOutcome
{
    valid,          /// names a nested directory
    tooManySlashes, /// "//" in the argument
    notNested,      /// nothing left after normalizing, e.g. "/"
    dotComponent,   /// a "." or ".." component
}

/// checkDirectoryArgument's result: what was found, and a message for her
/// to read. Design: docs/result-types.md
@mustuse struct DirectoryArgumentResult
{
    DirectoryArgumentOutcome outcome;
    string message; /// "" when outcome is valid
}

/**
 * The rules for a nested directory argument that don't need the disk: no
 * "//" (checked before normalizing, which would strip it), something left
 * after normalizing, and no "." or ".." component.
 *
 * Returns: valid, or the first rule broken and a message describing it.
 */
DirectoryArgumentResult checkDirectoryArgument(string argument)
{
    import std.algorithm.searching : canFind;
    import std.array : split;

    if (argument.canFind("//"))
    {
        return DirectoryArgumentResult(DirectoryArgumentOutcome.tooManySlashes,
            "too many slashes in directory '" ~ argument ~ "'");
    }
    immutable directory = GitRepos.normalizeDirectory(argument);
    if (directory.length == 0)
    {
        return DirectoryArgumentResult(DirectoryArgumentOutcome.notNested, "not a nested directory");
    }
    if (directory[1 .. $ - 1].split("/").canFind!(component => component == "." || component == ".."))
    {
        return DirectoryArgumentResult(DirectoryArgumentOutcome.dotComponent,
            "'.' and '..' are not allowed; give the directory relative to the parent");
    }
    return DirectoryArgumentResult(DirectoryArgumentOutcome.valid, "");
}

/// What entryFor found: the entry, or the stage that stopped it. The
/// message carries the detail (which rule, git's own words).
enum EntryOutcome
{
    found,                /// the entry is in the result
    badDirectoryArgument, /// checkDirectoryArgument refused the argument
    notRepository,        /// ParentDirectory.checkRepository: not a nested repo
    noOrigin,             /// no origin remote, and no --url given
    detachedHead,         /// no current branch, and no --branch given
    invalidEntry,         /// GitRepos.validate refused the entry
}

/// entryFor's result: what happened, a message for her to read, and the
/// entry. Design: docs/result-types.md
@mustuse struct EntryResult
{
    EntryOutcome outcome;
    string message;              /// "" when outcome is found
    GitReposEntry gitReposEntry; /// meaningful only when outcome is found
}

/**
 * Works out the .gitrepos entry for `argument`, a nested directory relative
 * to `parentDirectory`. `branch` and `url` are the --branch and --url
 * values ("" when not given). Reads only local git state, never the
 * network: origin/HEAD and origin's branches as last fetched.
 * `parentDirectory` is a path, not a ParentDirectory, on purpose.
 *
 * Returns: the entry, or which stage stopped it and why.
 */
EntryResult entryFor(string parentDirectory, string argument, string branch, string url)
{
    import std.path : buildPath;

    const directoryArgumentResult = checkDirectoryArgument(argument);
    with (DirectoryArgumentOutcome) final switch (directoryArgumentResult.outcome)
    {
    case valid:
        break;
    case tooManySlashes, notNested, dotComponent:
        return EntryResult(EntryOutcome.badDirectoryArgument, directoryArgumentResult.message);
    }
    immutable directory = GitRepos.normalizeDirectory(argument);

    immutable onDisk = buildPath(parentDirectory, directory[1 .. $ - 1]);
    const repositoryResult = ParentDirectory.checkRepository(directory, onDisk);
    with (RepositoryOutcome) final switch (repositoryResult.outcome)
    {
    case repository:
        break;
    case missing, notDirectory, notGitRepository, insideRepository:
        return EntryResult(EntryOutcome.notRepository, repositoryResult.message);
    }

    immutable origin = originUrl(onDisk);
    immutable recordedUrl = url.length ? url : origin;
    if (recordedUrl.length == 0)
    {
        return EntryResult(EntryOutcome.noOrigin, "it has no origin remote; give --url");
    }

    immutable current = currentBranch(onDisk);
    string recordedBranch = branch;
    if (recordedBranch.length == 0)
    {
        if (current.length == 0)
        {
            return EntryResult(EntryOutcome.detachedHead,
                "it has no current branch (detached HEAD); give --branch");
        }
        // origin/HEAD only describes origin, so it is unknown for another url.
        immutable remoteDefault = recordedUrl == origin ? remoteDefaultBranch(onDisk) : "";
        immutable omit = branchCanBeOmitted(directory, recordedUrl, current,
            (string candidate) => recordedUrl == origin && remoteHasBranch(onDisk, candidate), remoteDefault);
        recordedBranch = omit ? "" : current;
    }

    auto gitReposEntry = GitReposEntry(directory, recordedUrl, recordedBranch);
    const validationResult = GitRepos.validate(gitReposEntry);
    with (ValidationOutcome) final switch (validationResult.outcome)
    {
    case valid:
        return EntryResult(EntryOutcome.found, "", gitReposEntry);
    case tooManySlashesInDirectory, emptyDirectory, emptyUrl, tooManySlashesInUrl,
        tooManySlashesInBranch:
        return EntryResult(EntryOutcome.invalidEntry, validationResult.message);
    }
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

/// What cloneNested did.
enum CloneOutcome
{
    cloned,         /// cloned, and on the branch it should be on
    cloneFailed,    /// git clone failed; nothing was left behind
    checkoutFailed, /// cloned, but the branch couldn't be checked out; the clone stays
}

/// cloneNested's result: what happened, and a message for her to read.
/// Design: docs/result-types.md
@mustuse struct CloneResult
{
    CloneOutcome outcome;
    string message; /// "" when outcome is cloned
}

/**
 * Clones `url` into `onDisk` (which must not exist) and checks out the
 * branch branchAfterClone gives for the nested `directory` and
 * `listedBranch`. With no branch listed and a directory named differently
 * from the clone name, but no such branch on the remote, it notes on
 * `output` that the clone stays on the default branch. add-nested --clone
 * and pull-nested both clone this way.
 *
 * Returns: what happened, and a message for her when it failed. If the
 * clone itself failed, git leaves nothing behind; if only the checkout
 * failed, the clone stays.
 */
CloneResult cloneNested(string onDisk, string directory, string url, string listedBranch,
    File output, File errors)
{
    if (!runGit(["clone", url, onDisk], output, errors))
    {
        return CloneResult(CloneOutcome.cloneFailed, "git clone failed");
    }
    immutable target = branchAfterClone(directory, url, listedBranch,
        (string candidate) => remoteHasBranch(onDisk, candidate));
    if (target.length && currentBranch(onDisk) != target)
    {
        if (!runGit(["-C", onDisk, "checkout", "--quiet", target], output, errors))
        {
            return CloneResult(CloneOutcome.checkoutFailed,
                "cloned, but could not check out branch '" ~ target ~ "'");
        }
    }
    else if (target.length == 0 && listedBranch.length == 0 && namesDiffer(directory, url))
    {
        output.writeln("no branch \"", lastComponent(directory),
            "\" on the remote; staying on ", currentBranch(onDisk));
    }
    return CloneResult(CloneOutcome.cloned, "");
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
        CommonOptions commonOptions;
        assert(parseOptions(args, commonOptions, output, errors, "usage").proceed);
        assert(commonOptions.directory == "." && !commonOptions.fix);
        assert(args == ["add-nested", "alpha"]);

        args = ["add-nested", "-C", "/tmp/p", "--fix", "alpha", "beta"];
        commonOptions = CommonOptions.init;
        assert(parseOptions(args, commonOptions, output, errors, "usage").proceed);
        assert(commonOptions.directory == "/tmp/p" && commonOptions.fix);
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
        CommonOptions commonOptions;
        string branch;
        assert(parseOptions(args, commonOptions, output, errors, "usage",
            "branch", "Record this branch.", &branch).proceed);
        assert(branch == "dev" && commonOptions.fix && args == ["add-nested", "alpha"]);
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
            CommonOptions commonOptions;
            const parsed = parseOptions(args, commonOptions, output, errors, "Usage: check-nested [options]");
            assert(!parsed.proceed && parsed.exitStatus == ExitStatus.ok);
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
            CommonOptions commonOptions;
            const parsed = parseOptions(args, commonOptions, output, errors, "usage");
            assert(!parsed.proceed && parsed.exitStatus == ExitStatus.usage, bad[1]);
        });
        assert(text[0] == "" && text[1].canFind("check-nested: "), bad[1]);
    }
}

/// --no-check alone is parsed into CommonOptions.noCheck (#29); it is off
/// by default.
unittest
{
    immutable directory = testDirectory("nestedCommon-no-check");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto text = captured(directory, (File output, File errors) {
        string[] args = ["pull-nested", "-C", "/tmp/p"];
        CommonOptions commonOptions;
        assert(parseOptions(args, commonOptions, output, errors, "usage").proceed);
        assert(!commonOptions.noCheck);

        args = ["remove-nested", "--no-check", "alpha"];
        commonOptions = CommonOptions.init;
        assert(parseOptions(args, commonOptions, output, errors, "usage").proceed);
        assert(commonOptions.noCheck && !commonOptions.fix);
        assert(args == ["remove-nested", "alpha"]);
    });
    assert(text[0] == "" && text[1] == "");
}

/// --no-check with --fix is a usage error (2) in any order, and the message
/// names both (#29 decision 12).
unittest
{
    immutable directory = testDirectory("nestedCommon-no-check-fix");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    foreach (given; [["--no-check", "--fix"], ["--fix", "--no-check"]])
    {
        auto text = captured(directory, (File output, File errors) {
            string[] args = ["push-nested"] ~ given;
            CommonOptions commonOptions;
            const parsed = parseOptions(args, commonOptions, output, errors, "usage");
            assert(!parsed.proceed && parsed.exitStatus == ExitStatus.usage, given[0]);
        });
        assert(text[0] == "", given[0]);
        assert(text[1] == "push-nested: --no-check can't be used with --fix: with the checks off,"
            ~ " there is nothing for it to do\n", text[1]);
    }
}

/// checkOptionsGiven lists the common check options set, and
/// reportNoCheckConflict names them all, or prints nothing for none.
unittest
{
    immutable directory = testDirectory("nestedCommon-no-check-conflict");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    assert(checkOptionsGiven(CommonOptions.init) == []);
    CommonOptions commonOptions;
    commonOptions.fix = true;
    assert(checkOptionsGiven(commonOptions) == ["--fix"]);

    auto text = captured(directory, (File output, File errors) {
        assert(!reportNoCheckConflict("add-nested", [], errors));
        assert(reportNoCheckConflict("add-nested", ["--fix", "-f/--force"], errors));
    });
    assert(text[0] == "");
    assert(text[1] == "add-nested: --no-check can't be used with --fix, -f/--force: with the checks"
        ~ " off, there is nothing for them to do\n", text[1]);
}

/// Parsed.exitStatus is an ExitStatus: a bare number can't be stored in it,
/// and it converts to int for run() to return.
unittest
{
    static assert(is(typeof(Parsed.init.exitStatus) == ExitStatus));
    static assert(!__traits(compiles, { Parsed parsed; parsed.exitStatus = 5; }));
    static assert(__traits(compiles, { Parsed parsed; int status = parsed.exitStatus; }));
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
    bool has(string branch) { return branch == "blog"; }
    bool none(string branch) { return false; }

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
    bool has(string branch) { return branch == "blog"; }
    bool none(string branch) { return false; }

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

        const result = execute(["git"] ~ args);
        assert(result.status == 0, result.output);
    }

    /// A bare remote `<name>.git` in `scratch` with branches `branches` (the
    /// first is its default) and one commit; returns its path. (Test builds
    /// only; the commands' tests use it too.)
    string makeRemote(string scratch, string name, string[] branches...)
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
}

/// cloneNested's three outcomes, and what each leaves on disk.
unittest
{
    import std.file : exists;

    immutable directory = testDirectory("nestedCommon-cloneNested");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    // A remote with branches develop (default) and blog.
    immutable remote = buildPath(directory, "remote.git");
    immutable seed = buildPath(directory, "seed");
    git("init", "-q", "--bare", "-b", "develop", remote);
    git("init", "-q", "-b", "develop", seed);
    git("-C", seed, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
        "--allow-empty", "-m", "init");
    git("-C", seed, "push", "-q", remote, "develop", "develop:blog");

    CloneResult cloneResult;
    void clone(string name, string url, string listedBranch)
    {
        captured(directory, (File output, File errors) {
            cloneResult = cloneNested(buildPath(directory, name), "/" ~ name ~ "/", url,
                listedBranch, output, errors);
        });
    }

    clone("blog-copy", remote, "blog");
    assert(cloneResult.outcome == CloneOutcome.cloned && cloneResult.message == "");
    assert(currentBranch(buildPath(directory, "blog-copy")) == "blog");

    clone("nowhere", buildPath(directory, "missing.git"), "");
    assert(cloneResult.outcome == CloneOutcome.cloneFailed);
    assert(!buildPath(directory, "nowhere").exists);

    clone("kept", remote, "no-such-branch");
    assert(cloneResult.outcome == CloneOutcome.checkoutFailed);
    assert(buildPath(directory, "kept").exists);
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

    // No origin/HEAD, so the default is unknown. Since git 2.48, fetch
    // creates a missing origin/HEAD, so it's deleted to get this state on
    // every version (RelNotes/2.48.0 in git's source).
    immutable added = buildPath(directory, "added");
    git("init", "-q", added);
    git("-C", added, "remote", "add", "origin", remote);
    git("-C", added, "fetch", "-q", "origin");
    git("-C", added, "remote", "set-head", "origin", "--delete");
    assert(remoteDefaultBranch(added) == "");
    assert(remoteHasBranch(added, "blog"));

    // A repository with no remote: no default, no remote branches.
    immutable plain = buildPath(directory, "plain");
    git("init", "-q", plain);
    assert(remoteDefaultBranch(plain) == "" && !remoteHasBranch(plain, "blog"));
}

// --- tests: registering an existing clone ------------------------------------

/// checkDirectoryArgument's four outcomes.
unittest
{
    with (DirectoryArgumentOutcome)
    {
        assert(checkDirectoryArgument("alpha").outcome == valid);
        assert(checkDirectoryArgument("/tools/alpha/").outcome == valid);
        assert(checkDirectoryArgument("tools//alpha").outcome == tooManySlashes);
        assert(checkDirectoryArgument("/").outcome == notNested);
        assert(checkDirectoryArgument("").outcome == notNested);
        assert(checkDirectoryArgument("./alpha").outcome == dotComponent);
        assert(checkDirectoryArgument("tools/../alpha").outcome == dotComponent);
    }
    assert(checkDirectoryArgument("alpha").message == "");
}

/// entryFor's six outcomes; only `found` carries an entry.
unittest
{
    immutable scratch = testDirectory("nestedCommon-entryFor");
    scope (exit)
    {
        scratch.rmdirRecurse;
    }

    immutable remote = makeRemote(scratch, "alpha", "main");
    immutable parent = buildPath(scratch, "parent");
    git("clone", "-q", remote, buildPath(parent, "alpha"));
    git("init", "-q", "-b", "main", buildPath(parent, "lonely")); // no remote
    git("clone", "-q", remote, buildPath(parent, "detached"));
    git("-C", buildPath(parent, "detached"), "checkout", "-q", "--detach");

    with (EntryOutcome)
    {
        const entryResult = entryFor(parent, "alpha", "", "");
        assert(entryResult.outcome == found && entryResult.message == "");
        assert(entryResult.gitReposEntry == GitReposEntry("/alpha/", remote, ""));

        assert(entryFor(parent, "tools//alpha", "", "").outcome == badDirectoryArgument);
        assert(entryFor(parent, "missing", "", "").outcome == notRepository);
        assert(entryFor(parent, "lonely", "", "").outcome == noOrigin);
        assert(entryFor(parent, "detached", "", "").outcome == detachedHead);
        assert(entryFor(parent, "alpha", "feature//x", "").outcome == invalidEntry);

        // --url and --branch supply what the repository lacks.
        assert(entryFor(parent, "lonely", "", "l.git").outcome == found);
        assert(entryFor(parent, "detached", "main", "").outcome == found);
    }
}
