/**
 * ParentDirectory: a directory holding nested repos, with its .gitignore and
 * .gitrepos. It is the only place that works with both files, so they can
 * be kept in step. The directory need not be a git repository itself.
 *
 * Design: docs/nested-repos-design.md
 */
module parentDirectory;

import finding : Finding;
import gitIgnore : GitIgnore;
import gitRepos : GitRepos, GitReposEntry;

class ParentDirectory
{
    immutable string directory; /// the parent directory, as given

    // private: in D, private means private to this module, and this module
    // holds only ParentDirectory, so only its methods can replace these.
    // Commands go through add(), remove() and fix(), which keep both files
    // in step. https://dlang.org/spec/attribute.html#visibility_attributes
    // The trailing _ marks the field behind the read-only property of the
    // same name below; D won't let a field and a method share a name.
    private GitIgnore gitIgnore_;
    private GitRepos gitRepos_;

    /**
     * Reads `directory`/.gitignore and `directory`/.gitrepos. Either may be
     * missing.
     *
     * Throws: GitIgnoreException or GitReposException if a file is
     * malformed.
     */
    this(string directory = ".")
    {
        import std.path : buildPath;

        this.directory = directory;
        gitIgnore_ = new GitIgnore(buildPath(directory, ".gitignore"));
        gitRepos_ = new GitRepos(buildPath(directory, ".gitrepos"));
    }

    /// Read-only views of the two files.
    const(GitIgnore) gitIgnore() const @safe pure nothrow @nogc
    {
        return gitIgnore_;
    }

    /// ditto
    const(GitRepos) gitRepos() const @safe pure nothrow @nogc
    {
        return gitRepos_;
    }

    /**
     * Registers a nested repo in both files: the entry in .gitrepos
     * (replacing any for the same directory) and its directory pattern in
     * the .gitignore block (if not already there). Nothing is written until
     * write().
     *
     * .gitrepos goes first because GitRepos.add validates and normalizes
     * the entry: if it throws, neither file has changed.
     *
     * Throws: GitReposException for an entry parse() would refuse.
     */
    void add(GitReposEntry gitReposEntry)
    {
        import std.algorithm.searching : canFind;

        gitRepos_.add(gitReposEntry); // may throw; nothing changed yet if it does
        immutable pattern = GitRepos.normalizeDirectory(gitReposEntry.directory);
        if (!gitIgnore_.nested.canFind(pattern))
        {
            gitIgnore_.nested ~= pattern;
        }
    }

    /**
     * Unregisters a nested repo from both files. `directory` is normalized,
     * so "alpha" works. Never touches the directory on disk. Nothing is
     * written until write().
     *
     * Returns: true if either file had it.
     */
    bool remove(string directory)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        immutable pattern = GitRepos.normalizeDirectory(directory);
        immutable fromRepos = gitRepos_.remove(directory);

        immutable before = gitIgnore_.nested.length;
        gitIgnore_.nested = gitIgnore_.nested.filter!(existingPattern => existingPattern != pattern).array;
        immutable fromIgnore = gitIgnore_.nested.length != before;

        return fromRepos || fromIgnore;
    }

    /**
     * Problems with the two files, on their own and against each other.
     * Reads only the objects in memory, never the disk. Nothing is changed.
     *
     * In order:
     * 1. GitIgnore.check(), then GitRepos.check().
     * 2. A line outside the .gitignore block that names a .gitrepos
     *    directory (any slash form). Fixable: --fix moves it into the block.
     * 3. A .gitrepos directory with no block entry. Fixable: --fix adds the
     *    pattern. Not reported again if (2) already reported it.
     * 4. A block entry with no .gitrepos entry. Not fixable: there is no url
     *    to invent, so she decides.
     */
    Finding[] check() const
    {
        import std.algorithm.searching : canFind;

        Finding[] findings = gitIgnore_.check() ~ gitRepos_.check();

        bool[string] inRepos;
        string[] reposOrder; // distinct .gitrepos directories, in file order
        foreach (gitReposEntry; gitRepos_.gitReposEntries)
        {
            if (gitReposEntry.directory !in inRepos)
            {
                reposOrder ~= gitReposEntry.directory;
            }
            inRepos[gitReposEntry.directory] = true;
        }

        bool[string] loose;
        foreach (line; gitIgnore_.before ~ gitIgnore_.after)
        {
            immutable directory = looseDirectory(line);
            if (directory.length && directory in inRepos && directory !in loose)
            {
                loose[directory] = true;
                findings ~= Finding(directory, gitIgnore_.path ~ ": '" ~ line
                    ~ "' names nested repo " ~ directory
                    ~ " outside the managed block", true);
            }
        }

        foreach (directory; reposOrder)
        {
            if (!gitIgnore_.nested.canFind(directory) && directory !in loose)
            {
                findings ~= Finding(directory, gitRepos_.path ~ ": " ~ directory
                    ~ " is not in the managed block of " ~ gitIgnore_.path, true);
            }
        }

        bool[string] reported;
        foreach (pattern; gitIgnore_.nested)
        {
            if (GitIgnore.isDirectoryPattern(pattern) && pattern !in inRepos
                && pattern !in reported)
            {
                reported[pattern] = true;
                findings ~= Finding(pattern, gitIgnore_.path ~ ": " ~ pattern
                    ~ " is in the managed block but not in " ~ gitRepos_.path, false);
            }
        }

        return findings;
    }

    /**
     * Problems on disk with the nested repos .gitrepos lists. None is
     * fixable: a missing clone is pull-nested's job, and the rest need her
     * judgement. check() never touches the disk; this always does.
     *
     * For each distinct directory, in file order, the first problem found:
     * 1. it does not exist (#6);
     * 2. it is not a directory;
     * 3. `git -C <dir> rev-parse --show-toplevel` fails: not a git
     *    repository (git's own message is included);
     * 4. git names a different top level, compared after resolving symlinks
     *    on both sides: it is inside another repository, not one itself;
     * 5. no remote's url (`remote.<name>.url`, as stored, before any
     *    insteadOf rewriting) equals the url in .gitrepos.
     *
     * Git is run with an argument list, never through a shell, so names
     * with spaces are safe.
     */
    Finding[] checkDisk() const
    {
        import std.algorithm.searching : findSplit;
        import std.path : buildPath;
        import std.process : execute;
        import std.string : lineSplitter, strip;

        Finding[] findings;
        bool[string] seen;

        foreach (gitReposEntry; gitRepos_.gitReposEntries)
        {
            if (gitReposEntry.directory in seen)
            {
                continue;
            }
            seen[gitReposEntry.directory] = true;

            immutable onDisk = buildPath(directory, gitReposEntry.directory[1 .. $ - 1]);
            string problem = repositoryProblem(gitReposEntry.directory, onDisk);
            if (problem.length == 0)
            {
                // Lines are "remote.<name>.url <url>"; exit status 1 just
                // means there are no remotes.
                const urls = execute(["git", "-C", onDisk, "config",
                    "--get-regexp", `^remote\..*\.url$`]);
                bool found = false;
                foreach (line; urls.output.lineSplitter)
                {
                    auto nameAndUrl = line.strip.findSplit(" ");
                    if (nameAndUrl[1].length && nameAndUrl[2] == gitReposEntry.url)
                    {
                        found = true;
                        break;
                    }
                }
                if (!found)
                {
                    problem = "no remote of " ~ gitReposEntry.directory ~ " has url " ~ gitReposEntry.url;
                }
            }

            if (problem.length)
            {
                findings ~= Finding(gitReposEntry.directory, onDisk ~ ": " ~ problem, false);
            }
        }

        return findings;
    }

    /**
     * Why `onDisk` is not a nested repo, or "" if it is: it must exist, be
     * a directory, and be the top level of its own git repository
     * (`git rev-parse --show-toplevel` succeeds and names it, compared after
     * resolving symlinks). `directory` is how messages name it. checkDisk()
     * and add-nested both use this, so "is this a nested repo?" has one
     * answer.
     */
    static string repositoryProblem(string directory, string onDisk)
    {
        import std.file : exists, isDir;
        import std.process : execute;
        import std.string : strip;

        if (!onDisk.exists)
        {
            return directory ~ " does not exist";
        }
        if (!onDisk.isDir)
        {
            return directory ~ " is not a directory";
        }
        const top = execute(["git", "-C", onDisk, "rev-parse", "--show-toplevel"]);
        if (top.status != 0)
        {
            return directory ~ " is not a git repository (" ~ top.output.strip ~ ")";
        }
        if (resolvePath(top.output.strip) != resolvePath(onDisk))
        {
            return directory ~ " is inside the repository at " ~ top.output.strip
                ~ ", not a repository itself";
        }
        return "";
    }

    /// `path` with every symlink resolved (POSIX realpath(3)), or `path`
    /// itself if it can't be resolved.
    static string resolvePath(string path) @trusted
    {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.string : fromStringz, toStringz;

        auto resolved = realpath(path.toStringz, null);
        if (resolved is null)
        {
            return path;
        }
        scope (exit)
        {
            free(resolved);
        }
        return resolved.fromStringz.idup;
    }

    /**
     * Repairs, in memory, everything check() marks fixable. Nothing is
     * written until write().
     *
     * - Loose lines: a new GitIgnore is built without them in `before` and
     *   `after` (every other line, comments and blank lines included, stays
     *   exactly as it was), and their directories go into the block.
     * - .gitrepos directories missing from the block are added to it.
     * - The block is sorted and de-duplicated, and .gitrepos is sorted by
     *   directory (stably), so check() afterwards reports only what is left.
     *
     * Returns: check() after fixing, i.e. the findings she still has to
     * deal with, none of them fixable.
     */
    Finding[] fix()
    {
        import std.algorithm.iteration : filter, map;
        import std.algorithm.mutation : SwapStrategy;
        import std.algorithm.searching : canFind;
        import std.algorithm.sorting : sort;
        import std.array : array;

        bool[string] inRepos;
        foreach (gitReposEntry; gitRepos_.gitReposEntries)
        {
            inRepos[gitReposEntry.directory] = true;
        }

        string[] moved;
        bool keep(string line)
        {
            immutable directory = looseDirectory(line);
            if (directory.length && directory in inRepos)
            {
                moved ~= directory;
                return false;
            }
            return true;
        }

        immutable before = gitIgnore_.before.filter!(line => keep(line)).array;
        immutable after = gitIgnore_.after.filter!(line => keep(line)).array;
        string[] nested = gitIgnore_.nested ~ moved ~ gitRepos_.gitReposEntries
            .filter!(gitReposEntry => !gitIgnore_.nested.canFind(gitReposEntry.directory))
            .map!(gitReposEntry => gitReposEntry.directory).array;

        gitIgnore_ = new GitIgnore(gitIgnore_.path, before,
            GitIgnore.sortedUnique(nested), after, gitIgnore_.endsWithNewline);

        gitRepos_.gitReposEntries.sort!((left, right) => left.directory < right.directory, SwapStrategy.stable);

        return check();
    }

    /**
     * The "/alpha/" form of a .gitignore line if it could name a directory
     * (adding any missing leading or trailing slash), or "" if it can't:
     * empty, a comment, a negation, a wildcard, a doubled slash, or
     * surrounding whitespace (including a CRLF line's '\r').
     */
    static string looseDirectory(string line) @safe pure
    {
        import std.algorithm.searching : any, canFind;
        import std.ascii : isWhite;

        if (line.length == 0 || line[0] == '#' || line[0] == '!'
            || line.canFind("//") || line.any!(character => character == '*' || character == '?' || character == '[')
            || line[0].isWhite || line[$ - 1].isWhite)
        {
            return "";
        }
        return GitRepos.normalizeDirectory(line);
    }

    /**
     * Writes .gitrepos, then .gitignore, each atomically. The pair is not
     * atomic: a crash between the two can leave them disagreeing, which
     * check() reports on the next run.
     */
    void write() const
    {
        gitRepos_.write();
        gitIgnore_.write();
    }
}

// --- constructor / write() ---------------------------------------------------

version (unittest)
{
    import std.file : exists, readText, rmdirRecurse;
    import std.path : buildPath;
    import textFile : testDirectory;
}

/// A directory with neither file reads as empty, and writing creates nothing.
unittest
{
    immutable directory = testDirectory("parentDirectory-empty");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = new ParentDirectory(directory);
    assert(parentDirectory.directory == directory);
    assert(parentDirectory.gitIgnore.path == buildPath(directory, ".gitignore"));
    assert(parentDirectory.gitRepos.path == buildPath(directory, ".gitrepos"));
    assert(parentDirectory.gitIgnore.nested.length == 0 && parentDirectory.gitRepos.gitReposEntries.length == 0);

    parentDirectory.write();
    assert(!buildPath(directory, ".gitignore").exists);
    assert(!buildPath(directory, ".gitrepos").exists);
}

/// Both files are read from the directory and written back there.
unittest
{
    import std.file : write;
    import gitIgnore : beginMarker, endMarker;
    import gitRepos : GitReposEntry;

    immutable directory = testDirectory("parentDirectory-read-write");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable ignoreFile = buildPath(directory, ".gitignore");
    immutable reposFile = buildPath(directory, ".gitrepos");
    immutable ignoreText = "*.o\n" ~ beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n";
    immutable reposText = "/alpha/ git@github.com:pflagerd/alpha.git\n";
    ignoreFile.write(ignoreText);
    reposFile.write(reposText);

    auto parentDirectory = new ParentDirectory(directory);
    assert(parentDirectory.gitIgnore.nested == ["/alpha/"]);
    assert(parentDirectory.gitRepos.gitReposEntries == [GitReposEntry("/alpha/", "git@github.com:pflagerd/alpha.git", "")]);

    parentDirectory.write();
    assert(ignoreFile.readText == ignoreText);
    assert(reposFile.readText == reposText);
}

/// A malformed file is reported, not ignored.
unittest
{
    import std.exception : assertThrown;
    import std.file : write;
    import gitIgnore : GitIgnoreException, endMarker;
    import gitRepos : GitReposException;

    immutable directory = testDirectory("parentDirectory-malformed");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    buildPath(directory, ".gitignore").write(endMarker ~ "\n");
    assertThrown!GitIgnoreException(new ParentDirectory(directory));

    buildPath(directory, ".gitignore").write("");
    buildPath(directory, ".gitrepos").write("/alpha/\n");
    assertThrown!GitReposException(new ParentDirectory(directory));
}

/// The accessors are read-only: this must not compile.
unittest
{
    static assert(!__traits(compiles, (ParentDirectory parentDirectory) { parentDirectory.gitRepos.gitReposEntries = []; }));
    static assert(!__traits(compiles, (ParentDirectory parentDirectory) { parentDirectory.gitIgnore.nested ~= "/x/"; }));
}

// --- add() / remove() --------------------------------------------------------

/// add() registers in both files; write() puts it on disk.
unittest
{
    import gitIgnore : beginMarker, endMarker;

    immutable directory = testDirectory("parentDirectory-add");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = new ParentDirectory(directory);
    parentDirectory.add(GitReposEntry("alpha", "git@github.com:pflagerd/alpha.git", ""));
    assert(parentDirectory.gitRepos.gitReposEntries == [GitReposEntry("/alpha/", "git@github.com:pflagerd/alpha.git", "")]);
    assert(parentDirectory.gitIgnore.nested == ["/alpha/"]);
    assert(!buildPath(directory, ".gitrepos").exists); // nothing written yet

    parentDirectory.write();
    assert(buildPath(directory, ".gitrepos").readText == "/alpha/ git@github.com:pflagerd/alpha.git\n");
    assert(buildPath(directory, ".gitignore").readText
        == beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n");
}

/// Adding again replaces the .gitrepos entry and doesn't repeat the pattern.
unittest
{
    immutable directory = testDirectory("parentDirectory-add-again");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = new ParentDirectory(directory);
    parentDirectory.add(GitReposEntry("/alpha/", "old.git", ""));
    parentDirectory.add(GitReposEntry("alpha", "new.git", "dev"));
    assert(parentDirectory.gitRepos.gitReposEntries == [GitReposEntry("/alpha/", "new.git", "dev")]);
    assert(parentDirectory.gitIgnore.nested == ["/alpha/"]);
}

/// An invalid entry changes neither file.
unittest
{
    import std.exception : assertThrown;
    import gitRepos : GitReposException;

    immutable directory = testDirectory("parentDirectory-add-invalid");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = new ParentDirectory(directory);
    parentDirectory.add(GitReposEntry("/alpha/", "a.git", ""));
    assertThrown!GitReposException(parentDirectory.add(GitReposEntry("//beta/", "b.git", "")));
    assert(parentDirectory.gitRepos.gitReposEntries == [GitReposEntry("/alpha/", "a.git", "")]);
    assert(parentDirectory.gitIgnore.nested == ["/alpha/"]);
}

/// remove() takes it out of both files and never touches the directory.
unittest
{
    import std.file : mkdir;

    immutable directory = testDirectory("parentDirectory-remove");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable alphaOnDisk = buildPath(directory, "alpha");
    alphaOnDisk.mkdir;

    auto parentDirectory = new ParentDirectory(directory);
    parentDirectory.add(GitReposEntry("/alpha/", "a.git", ""));
    parentDirectory.add(GitReposEntry("/beta/", "b.git", ""));
    assert(parentDirectory.remove("alpha"));
    assert(parentDirectory.gitRepos.gitReposEntries == [GitReposEntry("/beta/", "b.git", "")]);
    assert(parentDirectory.gitIgnore.nested == ["/beta/"]);
    assert(alphaOnDisk.exists);

    assert(!parentDirectory.remove("/gamma/")); // in neither file
}

/// remove() also cleans up when only one file has the directory.
unittest
{
    import std.file : write;
    import gitIgnore : beginMarker, endMarker;

    immutable directory = testDirectory("parentDirectory-remove-one");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    buildPath(directory, ".gitignore").write(beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n");
    buildPath(directory, ".gitrepos").write("/beta/ b.git\n");

    auto parentDirectory = new ParentDirectory(directory);
    assert(parentDirectory.remove("alpha"));  // only in .gitignore
    assert(parentDirectory.gitIgnore.nested.length == 0);
    assert(parentDirectory.remove("/beta/")); // only in .gitrepos
    assert(parentDirectory.gitRepos.gitReposEntries.length == 0);
}

// --- check() -----------------------------------------------------------------

version (unittest)
{
    /// A ParentDirectory read from a directory holding these two files.
    private ParentDirectory withFiles(string directory, string ignoreText, string reposText)
    {
        import std.file : write;

        buildPath(directory, ".gitignore").write(ignoreText);
        buildPath(directory, ".gitrepos").write(reposText);
        return new ParentDirectory(directory);
    }
}

/// Files that agree have no findings.
unittest
{
    import gitIgnore : beginMarker, endMarker;

    immutable directory = testDirectory("parentDirectory-check-clean");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = withFiles(directory,
        "*.o\n" ~ beginMarker ~ "\n/alpha/\n/beta/\n" ~ endMarker ~ "\n",
        "/alpha/ a.git\n/beta/ b.git\n");
    assert(parentDirectory.check.length == 0);
}

/// A directory with neither file has no findings.
unittest
{
    immutable directory = testDirectory("parentDirectory-check-none");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    assert(new ParentDirectory(directory).check.length == 0);
}

/// Each file's own findings come first.
unittest
{
    import gitIgnore : beginMarker, endMarker;
    import std.algorithm.searching : canFind;

    immutable directory = testDirectory("parentDirectory-check-own");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = withFiles(directory,
        beginMarker ~ "\n/beta/\n/alpha/\n" ~ endMarker ~ "\n",
        "/beta/ b.git\n/alpha/ a.git\n");
    const findings = parentDirectory.check;
    assert(findings.length == 2);
    assert(findings[0].message.canFind(".gitignore") && findings[0].message.canFind("not sorted"));
    assert(findings[1].message.canFind(".gitrepos") && findings[1].message.canFind("not sorted"));
}

/// A loose line in any slash form is fixable, and isn't reported twice.
unittest
{
    import std.algorithm.searching : canFind;

    immutable directory = testDirectory("parentDirectory-check-loose");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    foreach (line; ["alpha", "/alpha", "alpha/", "/alpha/"])
    {
        auto parentDirectory = withFiles(directory, "*.o\n" ~ line ~ "\n", "/alpha/ a.git\n");
        const findings = parentDirectory.check;
        assert(findings.length == 1, line);
        assert(findings[0].directory == "/alpha/" && findings[0].fixable, line);
        assert(findings[0].message.canFind("outside the managed block"), line);
    }
}

/// A .gitrepos entry missing from the block is fixable; the reverse is not.
unittest
{
    import gitIgnore : beginMarker, endMarker;
    import std.algorithm.searching : canFind;

    immutable directory = testDirectory("parentDirectory-check-missing");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = withFiles(directory,
        beginMarker ~ "\n/alpha/\n/gamma/\n" ~ endMarker ~ "\n",
        "/alpha/ a.git\n/beta/ b.git\n");
    const findings = parentDirectory.check;
    assert(findings.length == 2);
    assert(findings[0].directory == "/beta/" && findings[0].fixable
        && findings[0].message.canFind("not in the managed block"));
    assert(findings[1].directory == "/gamma/" && !findings[1].fixable
        && findings[1].message.canFind("not in " ~ parentDirectory.gitRepos.path));
}

/// Lines that can't name a directory are never taken for loose repo lines.
unittest
{
    foreach (line; ["", "# alpha", "!alpha", "alph*", "al?ha", "[a]lpha",
                    "//alpha/", "alpha ", " alpha", "alpha\r"])
    {
        assert(ParentDirectory.looseDirectory(line) == "", line);
    }
    assert(ParentDirectory.looseDirectory("tools/alpha") == "/tools/alpha/");
}

/// Malformed block entries are left to GitIgnore.check(), not reported again.
unittest
{
    import gitIgnore : beginMarker, endMarker;

    immutable directory = testDirectory("parentDirectory-check-malformed");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = withFiles(directory, beginMarker ~ "\nalpha\n" ~ endMarker ~ "\n", "");
    const findings = parentDirectory.check;
    assert(findings.length == 1 && !findings[0].fixable); // GitIgnore's "not of the form"
}

// --- fix() -------------------------------------------------------------------

/// Loose lines move into the block; every other line stays exactly as it was.
unittest
{
    import gitIgnore : beginMarker, endMarker;

    immutable directory = testDirectory("parentDirectory-fix-loose");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = withFiles(directory,
        "# build\n*.o\nalpha\n\n" ~ beginMarker ~ "\n/beta/\n" ~ endMarker ~ "\n/gamma/\ntmp/\n",
        "/alpha/ a.git\n/beta/ b.git\n/gamma/ c.git\n");
    assert(parentDirectory.fix.length == 0);
    assert(parentDirectory.gitIgnore.before == ["# build", "*.o", ""]);
    assert(parentDirectory.gitIgnore.nested == ["/alpha/", "/beta/", "/gamma/"]);
    assert(parentDirectory.gitIgnore.after == ["tmp/"]);

    parentDirectory.write();
    assert(buildPath(directory, ".gitignore").readText ==
        "# build\n*.o\n\n" ~ beginMarker ~ "\n/alpha/\n/beta/\n/gamma/\n" ~ endMarker ~ "\ntmp/\n");
    assert(new ParentDirectory(directory).check.length == 0); // fixed on disk too
}

/// Missing block entries are added; a file with no block gets one.
unittest
{
    import gitIgnore : beginMarker, endMarker;

    immutable directory = testDirectory("parentDirectory-fix-missing");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = withFiles(directory, "*.o", "/beta/ b.git\n/alpha/ a.git\n");
    assert(parentDirectory.fix.length == 0);
    assert(parentDirectory.gitIgnore.nested == ["/alpha/", "/beta/"]);
    assert(parentDirectory.gitRepos.gitReposEntries[0].directory == "/alpha/"); // .gitrepos sorted too
    parentDirectory.write();
    assert(buildPath(directory, ".gitignore").readText ==
        "*.o\n" ~ beginMarker ~ "\n/alpha/\n/beta/\n" ~ endMarker ~ "\n");
}

/// What can't be fixed is returned, and left alone.
unittest
{
    import gitIgnore : beginMarker, endMarker;
    import std.algorithm.searching : canFind;

    immutable directory = testDirectory("parentDirectory-fix-unfixable");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto parentDirectory = withFiles(directory,
        beginMarker ~ "\n/delta/\n/beta/\n/beta/\n" ~ endMarker ~ "\n",
        "/beta/ b.git\n/alpha/ a.git\n/alpha/ a2.git\n");
    const remaining = parentDirectory.fix;
    assert(remaining.length == 2);
    foreach (finding; remaining)
    {
        assert(!finding.fixable);
    }
    assert(remaining[0].directory == "/alpha/" && remaining[0].message.canFind("listed 2 times"));
    assert(remaining[1].directory == "/delta/" && remaining[1].message.canFind("not in"));
    assert(parentDirectory.gitIgnore.nested == ["/alpha/", "/beta/", "/delta/"]); // /delta/ kept
}

/// fix() on files that agree changes nothing, and a second fix() is a no-op.
unittest
{
    import gitIgnore : beginMarker, endMarker;

    immutable directory = testDirectory("parentDirectory-fix-idempotent");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable ignoreText = "*.o\n" ~ beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n";
    auto alreadyFixed = withFiles(directory, ignoreText, "/alpha/ a.git\n");
    assert(alreadyFixed.fix.length == 0);
    assert(alreadyFixed.gitIgnore.content == ignoreText);

    auto needsFixing = withFiles(directory, "alpha\n", "/alpha/ a.git\n");
    needsFixing.fix();
    immutable once = needsFixing.gitIgnore.content;
    needsFixing.fix();
    assert(needsFixing.gitIgnore.content == once);
}

// --- checkDisk() ---------------------------------------------------------------

version (unittest)
{
    /// Runs git with `args`, failing the test if it fails.
    private void git(string[] args...)
    {
        import std.process : execute;

        const result = execute(["git"] ~ args);
        assert(result.status == 0, result.output);
    }
}

/// Real nested repos with the listed remote have no findings, including
/// through a symlinked parent and with a name containing a space.
unittest
{
    import std.file : symlink, write;

    immutable directory = testDirectory("parentDirectory-disk-clean");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable real_ = buildPath(directory, "real");
    git("init", "-q", buildPath(real_, "alpha"));
    git("-C", buildPath(real_, "alpha"), "remote", "add", "origin", "git@github.com:pflagerd/alpha.git");
    git("init", "-q", buildPath(real_, "My Repo"));
    git("-C", buildPath(real_, "My Repo"), "remote", "add", "upstream", "/srv/git/my repo.git");
    buildPath(real_, ".gitrepos").write(
        "/My%20Repo/ /srv/git/my%20repo.git\n/alpha/ git@github.com:pflagerd/alpha.git\n");

    assert(new ParentDirectory(real_).checkDisk.length == 0);

    immutable link = buildPath(directory, "link");
    real_.symlink(link);
    assert(new ParentDirectory(link).checkDisk.length == 0);
}

/// Each kind of problem is reported once per directory, in file order.
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : mkdir, write;

    immutable directory = testDirectory("parentDirectory-disk-problems");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    buildPath(directory, "file").write("not a directory\n");
    buildPath(directory, "plain").mkdir;
    git("init", "-q", buildPath(directory, "other"));
    git("-C", buildPath(directory, "other"), "remote", "add", "origin", "other.git");
    buildPath(directory, ".gitrepos").write(
        "/missing/ m.git\n/file/ f.git\n/plain/ p.git\n/other/ wanted.git\n/missing/ again.git\n");

    const findings = new ParentDirectory(directory).checkDisk;
    assert(findings.length == 4);
    assert(findings[0].directory == "/missing/" && findings[0].message.canFind("does not exist"));
    assert(findings[1].directory == "/file/" && findings[1].message.canFind("not a directory"));
    assert(findings[2].directory == "/plain/" && findings[2].message.canFind("not a git repository")
        && findings[2].message.canFind("fatal:")); // git's own message
    assert(findings[3].directory == "/other/" && findings[3].message.canFind("no remote")
        && findings[3].message.canFind("wanted.git"));
    foreach (finding; findings)
    {
        assert(!finding.fixable);
    }
}

/// A plain folder inside a repository is not mistaken for a nested repo.
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : mkdir, write;

    immutable directory = testDirectory("parentDirectory-disk-inside");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    git("init", "-q", directory); // the parent itself is a repository
    buildPath(directory, "alpha").mkdir;
    buildPath(directory, ".gitrepos").write("/alpha/ a.git\n");

    const findings = new ParentDirectory(directory).checkDisk;
    assert(findings.length == 1);
    assert(findings[0].message.canFind("inside the repository at"));
}

/// Any remote may carry the url, not only origin; a repo with no remotes fails.
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : write;

    immutable directory = testDirectory("parentDirectory-disk-remotes");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    git("init", "-q", buildPath(directory, "alpha"));
    git("-C", buildPath(directory, "alpha"), "remote", "add", "origin", "first.git");
    git("-C", buildPath(directory, "alpha"), "remote", "add", "backup", "second.git");
    git("init", "-q", buildPath(directory, "beta"));
    buildPath(directory, ".gitrepos").write("/alpha/ second.git\n/beta/ b.git\n");

    const findings = new ParentDirectory(directory).checkDisk;
    assert(findings.length == 1);
    assert(findings[0].directory == "/beta/" && findings[0].message.canFind("no remote"));
}
