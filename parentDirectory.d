/**
 * ParentDirectory: a directory holding nested repos, with its .gitignore and
 * .gitrepos. It is the only place that works with both files, so they can
 * be kept in step. The directory need not be a git repository itself.
 *
 * Design: docs/nested-repos-design.md
 */
module parentDirectory;

import gitIgnore : GitIgnore;
import gitRepos : GitRepos, GitReposEntry;

class ParentDirectory
{
    immutable string directory; /// the parent directory, as given

    // private: in D, private means private to this module, and this module
    // holds only ParentDirectory, so only its methods can replace these.
    // Commands go through add(), remove() and fix(), which keep both files
    // in step. https://dlang.org/spec/attribute.html#visibility_attributes
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
    void add(GitReposEntry entry)
    {
        import std.algorithm.searching : canFind;

        gitRepos_.add(entry); // may throw; nothing changed yet if it does
        immutable pattern = GitRepos.normalizeDirectory(entry.directory);
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
        gitIgnore_.nested = gitIgnore_.nested.filter!(p => p != pattern).array;
        immutable fromIgnore = gitIgnore_.nested.length != before;

        return fromRepos || fromIgnore;
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

    auto p = new ParentDirectory(directory);
    assert(p.directory == directory);
    assert(p.gitIgnore.path == buildPath(directory, ".gitignore"));
    assert(p.gitRepos.path == buildPath(directory, ".gitrepos"));
    assert(p.gitIgnore.nested.length == 0 && p.gitRepos.entries.length == 0);

    p.write();
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

    auto p = new ParentDirectory(directory);
    assert(p.gitIgnore.nested == ["/alpha/"]);
    assert(p.gitRepos.entries == [GitReposEntry("/alpha/", "git@github.com:pflagerd/alpha.git", "")]);

    p.write();
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
    static assert(!__traits(compiles, (ParentDirectory p) { p.gitRepos.entries = []; }));
    static assert(!__traits(compiles, (ParentDirectory p) { p.gitIgnore.nested ~= "/x/"; }));
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

    auto p = new ParentDirectory(directory);
    p.add(GitReposEntry("alpha", "git@github.com:pflagerd/alpha.git", ""));
    assert(p.gitRepos.entries == [GitReposEntry("/alpha/", "git@github.com:pflagerd/alpha.git", "")]);
    assert(p.gitIgnore.nested == ["/alpha/"]);
    assert(!buildPath(directory, ".gitrepos").exists); // nothing written yet

    p.write();
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

    auto p = new ParentDirectory(directory);
    p.add(GitReposEntry("/alpha/", "old.git", ""));
    p.add(GitReposEntry("alpha", "new.git", "dev"));
    assert(p.gitRepos.entries == [GitReposEntry("/alpha/", "new.git", "dev")]);
    assert(p.gitIgnore.nested == ["/alpha/"]);
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

    auto p = new ParentDirectory(directory);
    p.add(GitReposEntry("/alpha/", "a.git", ""));
    assertThrown!GitReposException(p.add(GitReposEntry("//beta/", "b.git", "")));
    assert(p.gitRepos.entries == [GitReposEntry("/alpha/", "a.git", "")]);
    assert(p.gitIgnore.nested == ["/alpha/"]);
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

    auto p = new ParentDirectory(directory);
    p.add(GitReposEntry("/alpha/", "a.git", ""));
    p.add(GitReposEntry("/beta/", "b.git", ""));
    assert(p.remove("alpha"));
    assert(p.gitRepos.entries == [GitReposEntry("/beta/", "b.git", "")]);
    assert(p.gitIgnore.nested == ["/beta/"]);
    assert(alphaOnDisk.exists);

    assert(!p.remove("/gamma/")); // in neither file
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

    auto p = new ParentDirectory(directory);
    assert(p.remove("alpha"));  // only in .gitignore
    assert(p.gitIgnore.nested.length == 0);
    assert(p.remove("/beta/")); // only in .gitrepos
    assert(p.gitRepos.entries.length == 0);
}
