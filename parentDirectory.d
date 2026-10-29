/**
 * ParentDirectory: a directory holding nested repos, with its .gitignore and
 * .gitrepos. It is the only place that works with both files, so they can
 * be kept in step. The directory need not be a git repository itself.
 *
 * Design: docs/nested-repos-design.md
 */
module parentDirectory;

import gitIgnore : GitIgnore;
import gitRepos : GitRepos;

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
