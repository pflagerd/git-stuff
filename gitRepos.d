/**
 * GitRepos: one .gitrepos file, listing the nested repos of a parent
 * directory, one per line:
 *
 *   <directory> <url> [<branch>]
 *
 *   /alpha/ git@github.com:pflagerd/alpha.git
 *   /beta/ git@github.com:pflagerd/beta.git dev
 *
 * The whole file is managed by the tools: blank lines and lines starting
 * with '#' are skipped when reading and not written back.
 *
 * Design: docs/nested-repos-design.md
 */
module gitRepos;

import std.conv : to;

import finding : Finding;
import textFile : readIfExists, splitFileLines, writeAtomically;

/// One line of .gitrepos.
struct GitReposEntry
{
    string directory; /// relative to the parent directory, always "/alpha/" form
    string url;       /// a git URL as git-clone defines it (https://git-scm.com/docs/git-clone#_git_urls)
    string branch;    /// optional; "" means not given
}

/// Thrown when a .gitrepos line can't be parsed.
class GitReposException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(message, file, line);
    }
}

class GitRepos
{
    immutable string path;   /// where it was read from; write()'s default
    GitReposEntry[] gitReposEntries; /// in file order, duplicates included

    /**
     * Reads and parses `path`. A missing file is not an error: it reads as
     * having no entries.
     *
     * Throws: GitReposException for a line that can't be parsed.
     */
    this(string path = ".gitrepos")
    {
        this.path = path;

        bool finalNewline; // not needed: the file is always written with one
        gitReposEntries = parse(splitFileLines(readIfExists(path), finalNewline));
    }

    /**
     * Parses the lines of a .gitrepos.
     *
     * Fields are separated by runs of whitespace, so older files with double
     * spaces or tabs still read. Each field is unescaped (see unescapeField),
     * and the directory is normalized to "/alpha/" form.
     *
     * Throws: GitReposException for a line with fewer than two or more than
     * three fields, an empty directory, or more than one consecutive slash
     * in any field (except where urlSlashesOk allows it in a url). Line
     * numbers start at 1.
     */
    static GitReposEntry[] parse(const string[] lines) @safe pure
    {
        import std.array : split;
        import std.string : strip;

        GitReposEntry[] gitReposEntries;

        foreach (i, line; lines)
        {
            immutable lineNumber = i + 1;
            immutable trimmed = line.strip;

            if (trimmed.length == 0 || trimmed[0] == '#')
            {
                continue;
            }

            const fields = trimmed.split;
            if (fields.length < 2 || fields.length > 3)
            {
                throw new GitReposException("line " ~ lineNumber.to!string
                    ~ ": expected <directory> <url> [<branch>], found "
                    ~ fields.length.to!string ~ " field(s)");
            }

            auto gitReposEntry = GitReposEntry(unescapeField(fields[0]), unescapeField(fields[1]),
                fields.length == 3 ? unescapeField(fields[2]) : "");
            immutable problem = validate(gitReposEntry);
            if (problem !is null)
            {
                throw new GitReposException("line " ~ lineNumber.to!string ~ ": " ~ problem);
            }
            gitReposEntries ~= gitReposEntry;
        }

        return gitReposEntries;
    }

    /**
     * Normalizes `gitReposEntry.directory` to "/alpha/" form and checks the entry
     * against the rules both parse() and add() enforce. Returns a message
     * describing the first problem, or null if there is none.
     */
    static string validate(ref GitReposEntry gitReposEntry) @safe pure
    {
        import std.algorithm.searching : canFind;

        if (gitReposEntry.directory.canFind("//"))
        {
            return "too many slashes in directory '" ~ gitReposEntry.directory ~ "'";
        }
        gitReposEntry.directory = normalizeDirectory(gitReposEntry.directory);
        if (gitReposEntry.directory.length == 0)
        {
            return "empty directory";
        }
        if (gitReposEntry.url.length == 0)
        {
            return "empty url";
        }
        if (!urlSlashesOk(gitReposEntry.url))
        {
            return "too many slashes in url '" ~ gitReposEntry.url ~ "'";
        }
        // git-check-ref-format: no multiple consecutive slashes.
        if (gitReposEntry.branch.canFind("//"))
        {
            return "too many slashes in branch '" ~ gitReposEntry.branch ~ "'";
        }
        return null;
    }

    /**
     * Adds `gitReposEntry`, replacing every existing entry with the same directory.
     * The directory is normalized first, so add("alpha", ...) and
     * add("/alpha/", ...) mean the same.
     *
     * Throws: GitReposException if the entry breaks the rules parse()
     * enforces (see validate), so write() never produces a file that
     * won't parse.
     */
    void add(GitReposEntry gitReposEntry) @safe
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        immutable problem = validate(gitReposEntry);
        if (problem !is null)
        {
            throw new GitReposException("add(): " ~ problem);
        }
        gitReposEntries = gitReposEntries.filter!(existing => existing.directory != gitReposEntry.directory).array ~ gitReposEntry;
    }

    /**
     * Removes every entry for `directory` (normalized first, so "alpha"
     * works). Never touches the directory on disk.
     *
     * Returns: true if anything was removed.
     */
    bool remove(string directory) @safe
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        immutable target = normalizeDirectory(directory);
        immutable before = gitReposEntries.length;
        gitReposEntries = gitReposEntries.filter!(gitReposEntry => gitReposEntry.directory != target).array;
        return gitReposEntries.length != before;
    }

    /**
     * Problems with the entries. Nothing is changed.
     *
     * - Entries are not sorted by directory (fixable: write() sorts them).
     * - A directory is listed more than once (not fixable: which url or
     *   branch is right is her call). One finding per directory, saying how
     *   many times it is listed.
     *
     * Findings come in a fixed order: "not sorted" first, then duplicates in
     * the order their directories first appear. Everything else that could
     * be wrong with a line is already refused by parse().
     */
    Finding[] check() const @safe pure
    {
        import std.algorithm.sorting : isSorted;

        Finding[] findings;

        if (!gitReposEntries.isSorted!((left, right) => left.directory < right.directory))
        {
            findings ~= Finding("", path ~ ": entries are not sorted by directory", true);
        }

        size_t[string] count;
        string[] order; // directories in order of first appearance
        foreach (gitReposEntry; gitReposEntries)
        {
            if (gitReposEntry.directory !in count)
            {
                order ~= gitReposEntry.directory;
            }
            ++count[gitReposEntry.directory];
        }
        foreach (directory; order)
        {
            if (count[directory] > 1)
            {
                findings ~= Finding(directory, path ~ ": " ~ directory ~ " is listed "
                    ~ count[directory].to!string ~ " times", false);
            }
        }

        return findings;
    }

    /**
     * The file text write() would produce: one line per entry, sorted by
     * directory (a stable sort, so duplicates keep their order for check()),
     * fields escaped and separated by single spaces, the branch left out
     * when empty, and a final newline. No entries gives "".
     */
    string content() const @safe pure
    {
        import std.algorithm.mutation : SwapStrategy;
        import std.algorithm.sorting : sort;

        auto sorted = gitReposEntries.dup;
        sorted.sort!((left, right) => left.directory < right.directory, SwapStrategy.stable);

        string text;
        foreach (gitReposEntry; sorted)
        {
            text ~= escapeField(gitReposEntry.directory) ~ " " ~ escapeField(gitReposEntry.url);
            if (gitReposEntry.branch.length)
            {
                text ~= " " ~ escapeField(gitReposEntry.branch);
            }
            text ~= "\n";
        }
        return text;
    }

    /**
     * Writes content() to `toPath`, or by default to the path it was read
     * from, using textFile.writeAtomically (temporary file, then rename;
     * permissions kept). A file that doesn't exist and would be empty is not
     * created; an existing file whose entries were all removed is written
     * empty, not deleted.
     */
    void write(string toPath = null) const
    {
        import std.file : exists;

        immutable target = toPath is null ? path : toPath;
        immutable text = content();
        if (text.length == 0 && !target.exists)
        {
            return;
        }
        writeAtomically(target, text);
    }

    /**
     * Whether `url`'s slashes are acceptable: no "//" anywhere, except the
     * "//" after a scheme ("ssh://", "https://"; RFC 3986 section 3), plus
     * one more "/" for file URLs with an empty host ("file:///srv/x.git";
     * RFC 8089). scp-like urls ("git@host:path") and local paths get no
     * exception. Forms: https://git-scm.com/docs/git-clone#_git_urls
     */
    static bool urlSlashesOk(string url) @safe pure
    {
        import std.algorithm.searching : all, canFind, findSplit;
        import std.ascii : isAlpha, isAlphaNum;

        auto parts = url.findSplit("://");
        immutable scheme = parts[0];
        // RFC 3986: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
        immutable hasScheme = parts[1].length && scheme.length && scheme[0].isAlpha
            && scheme.all!(character => character.isAlphaNum || character == '+' || character == '-' || character == '.');
        if (!hasScheme)
        {
            return !url.canFind("//");
        }

        string rest = parts[2];
        if (scheme == "file" && rest.length && rest[0] == '/')
        {
            rest = rest[1 .. $]; // empty host: file:///path
        }
        // Any slash still at the front would make a run longer than allowed
        // ("ssh:///x", "file:////x"), so it's checked as well as "//" later on.
        return !(rest.length && rest[0] == '/') && !rest.canFind("//");
    }

    /**
     * `directory` in "/alpha/" form: a missing leading or trailing slash is
     * added. Returns "" if nothing is left. parse() rejects "//" before
     * calling this, so at most one slash is stripped from each end.
     */
    static string normalizeDirectory(string directory) @safe pure
    {
        import std.string : strip;

        immutable bare = directory.strip("/");
        return bare.length ? "/" ~ bare ~ "/" : "";
    }
}

/**
 * Escapes the characters that would break a space-separated .gitrepos line,
 * and only those: '%' (so escapes can't be confused with text), space, tab
 * and newline. Everything else, including '@', ':' and '/', is left alone so
 * ordinary lines stay readable.
 */
string escapeField(string field) @safe pure
{
    import std.array : replace;

    // '%' first, so the '%' of the other escapes isn't escaped again.
    return field.replace("%", "%25").replace(" ", "%20")
        .replace("\t", "%09").replace("\n", "%0A");
}

/**
 * Reverses escapeField. Only its four sequences are decoded; any other
 * "%XX" is left as is, so older files containing literal text such as
 * "%2E" read correctly.
 */
string unescapeField(string field) @safe pure
{
    import std.array : appender;

    auto result = appender!string;
    size_t i = 0;
    while (i < field.length)
    {
        if (field[i] == '%' && i + 3 <= field.length)
        {
            immutable sequence = field[i .. i + 3];
            immutable decoded = sequence == "%25" ? "%"
                : sequence == "%20" ? " "
                : sequence == "%09" ? "\t"
                : sequence == "%0A" ? "\n"
                : null;
            if (decoded !is null)
            {
                result ~= decoded;
                i += 3;
                continue;
            }
        }
        result ~= field[i];
        ++i;
    }
    return result[];
}

// --- escapeField() / unescapeField() ---------------------------------------

/// Ordinary fields are untouched.
unittest
{
    foreach (field; ["/alpha/", "git@github.com:pflagerd/alpha.git",
                 "https://github.com/pflagerd/alpha.git", "dev"])
    {
        assert(escapeField(field) == field);
        assert(unescapeField(field) == field);
    }
}

/// The four characters are escaped, '%' without double-escaping the others.
unittest
{
    assert(escapeField("My Repo") == "My%20Repo");
    assert(escapeField("a\tb\nc") == "a%09b%0Ac");
    assert(escapeField("100%") == "100%25");
    assert(escapeField("% ") == "%25%20");
}

/// Only the four sequences decode; other %XX and a trailing % stay as is.
unittest
{
    assert(unescapeField("My%20Repo") == "My Repo");
    assert(unescapeField("a%09b%0Ac%25") == "a\tb\nc%");
    assert(unescapeField("foo%2Ebar") == "foo%2Ebar");
    assert(unescapeField("100%") == "100%");
    assert(unescapeField("%2") == "%2");
    assert(unescapeField("%0a") == "%0a"); // only the upper-case form escapeField writes
}

/// unescapeField(escapeField(s)) == s, including strings that look escaped.
unittest
{
    foreach (field; ["", "plain", "My Repo", "100%", "%20", "%2520", "a\tb\nc",
                 "foo%2Ebar", "% %25 %%", "trailing%"])
    {
        assert(unescapeField(escapeField(field)) == field, field);
    }
}

// --- normalizeDirectory() ------------------------------------------------

/// Every slash form becomes /alpha/; nested paths keep their inner slash.
unittest
{
    foreach (directory; ["alpha", "/alpha", "alpha/", "/alpha/"])
    {
        assert(GitRepos.normalizeDirectory(directory) == "/alpha/", directory);
    }
    assert(GitRepos.normalizeDirectory("tools/alpha") == "/tools/alpha/");
    assert(GitRepos.normalizeDirectory("/") == "");
    assert(GitRepos.normalizeDirectory("") == "");
}

// --- parse() ---------------------------------------------------------------

/// Two and three fields; the directory is normalized.
unittest
{
    auto gitReposEntries = GitRepos.parse([
        "/alpha/ git@github.com:pflagerd/alpha.git",
        "beta git@github.com:pflagerd/beta.git dev",
    ]);
    assert(gitReposEntries.length == 2);
    assert(gitReposEntries[0] == GitReposEntry("/alpha/", "git@github.com:pflagerd/alpha.git", ""));
    assert(gitReposEntries[1] == GitReposEntry("/beta/", "git@github.com:pflagerd/beta.git", "dev"));
}

/// Blank lines and comments are skipped; file order and duplicates are kept.
unittest
{
    auto gitReposEntries = GitRepos.parse([
        "# nested repos", "",
        "/beta/ b.git", "   ", "  # indented comment",
        "/alpha/ a.git", "/beta/ other.git",
    ]);
    assert(gitReposEntries.length == 3);
    assert(gitReposEntries[0].directory == "/beta/" && gitReposEntries[1].directory == "/alpha/");
    assert(gitReposEntries[2] == GitReposEntry("/beta/", "other.git", ""));
}

/// Runs of spaces or tabs separate fields; a CRLF line's '\r' is dropped.
unittest
{
    auto gitReposEntries = GitRepos.parse(["/alpha/  a.git\tdev", "/beta/ b.git\r"]);
    assert(gitReposEntries[0] == GitReposEntry("/alpha/", "a.git", "dev"));
    assert(gitReposEntries[1] == GitReposEntry("/beta/", "b.git", ""));
}

/// Escaped fields are decoded.
unittest
{
    auto gitReposEntries = GitRepos.parse(["/My%20Repo/ /srv/git/my%20repo.git my%25branch"]);
    assert(gitReposEntries[0] == GitReposEntry("/My Repo/", "/srv/git/my repo.git", "my%branch"));
}

/// Wrong field counts and an empty directory throw, naming the line.
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    auto exception = collectException!GitReposException(GitRepos.parse(["# c", "/alpha/"]));
    assert(exception && exception.msg.canFind("line 2") && exception.msg.canFind("1 field"));

    exception = collectException!GitReposException(GitRepos.parse(["/a/ a.git dev extra"]));
    assert(exception && exception.msg.canFind("line 1") && exception.msg.canFind("4 field"));

    exception = collectException!GitReposException(GitRepos.parse(["/ a.git"]));
    assert(exception && exception.msg.canFind("line 1") && exception.msg.canFind("empty directory"));
}

/// urlSlashesOk: "//" only right after a scheme, plus one "/" for file:.
unittest
{
    foreach (url; [
        "git@github.com:pflagerd/alpha.git",       // scp-like
        "ssh://git@github.com/pflagerd/alpha.git",
        "ssh://git@github.com:22/pflagerd/alpha.git",
        "https://github.com/pflagerd/alpha.git",
        "git+ssh://host/x.git",                    // scheme with '+'
        "file:///srv/git/alpha.git",               // empty host
        "file://host/srv/git/alpha.git",
        "/srv/git/alpha.git",                      // local path
        "../alpha.git",
    ])
    {
        assert(GitRepos.urlSlashesOk(url), url);
    }

    foreach (url; [
        "git@github.com:pflagerd//alpha.git",
        "git@github.com://pflagerd/alpha.git",     // not a scheme: '@' in it
        "ssh:///host/x.git",                       // extra '/' only for file:
        "https://github.com//pflagerd/alpha.git",
        "file:////srv/git/alpha.git",
        "file:///srv//git/alpha.git",
        "//srv/git/alpha.git",
        "/srv/git//alpha.git",
        "1http://host/x.git",                      // scheme must start with a letter
    ])
    {
        assert(!GitRepos.urlSlashesOk(url), url);
    }
}

/// Too many slashes in a url or branch throws, naming the line.
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    auto exception = collectException!GitReposException(
        GitRepos.parse(["/ok/ ok.git", "/a/ git@github.com:pflagerd//a.git"]));
    assert(exception && exception.msg.canFind("line 2") && exception.msg.canFind("too many slashes in url"));

    exception = collectException!GitReposException(
        GitRepos.parse(["/a/ a.git feature//x"]));
    assert(exception && exception.msg.canFind("line 1") && exception.msg.canFind("too many slashes in branch"));

    // A branch with single slashes is fine.
    assert(GitRepos.parse(["/a/ a.git feature/x"])[0].branch == "feature/x");
}

/// A doubled slash anywhere in the directory throws, naming the line.
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    foreach (directory; ["//alpha/", "/alpha//", "/tools//alpha/", "//"])
    {
        auto exception = collectException!GitReposException(
            GitRepos.parse(["/ok/ ok.git", directory ~ " a.git"]));
        assert(exception && exception.msg.canFind("line 2") && exception.msg.canFind("too many slashes"), directory);
    }
}

// --- constructor -----------------------------------------------------------

/// Reads a real file; a missing file has no entries.
unittest
{
    import std.file : rmdirRecurse, write;
    import std.path : buildPath;
    import textFile : testDirectory;

    immutable directory = testDirectory("gitRepos-constructor");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable file = buildPath(directory, ".gitrepos");
    auto missing = new GitRepos(file);
    assert(missing.path == file && missing.gitReposEntries.length == 0);

    file.write("/alpha/ git@github.com:pflagerd/alpha.git\n/beta/ b.git dev\n");
    auto gitRepos = new GitRepos(file);
    assert(gitRepos.gitReposEntries == [
        GitReposEntry("/alpha/", "git@github.com:pflagerd/alpha.git", ""),
        GitReposEntry("/beta/", "b.git", "dev"),
    ]);
}

// --- test helpers ----------------------------------------------------------

version (unittest)
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    import textFile : testDirectory;

    /// A GitRepos read from a file holding `text`.
    private GitRepos fromText(string directory, string text)
    {
        import std.file : write;

        immutable file = buildPath(directory, ".gitrepos");
        file.write(text);
        return new GitRepos(file);
    }
}

// --- add() / remove() ------------------------------------------------------

/// add() appends a new entry, normalizing its directory.
unittest
{
    immutable directory = testDirectory("gitRepos-add");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto gitRepos = fromText(directory, "/beta/ b.git\n");
    gitRepos.add(GitReposEntry("alpha", "git@github.com:pflagerd/alpha.git", ""));
    assert(gitRepos.gitReposEntries == [
        GitReposEntry("/beta/", "b.git", ""),
        GitReposEntry("/alpha/", "git@github.com:pflagerd/alpha.git", ""),
    ]);
}

/// add() replaces every entry with the same directory, duplicates included.
unittest
{
    immutable directory = testDirectory("gitRepos-add-replace");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto gitRepos = fromText(directory, "/alpha/ old.git\n/beta/ b.git\n/alpha/ older.git dev\n");
    gitRepos.add(GitReposEntry("/alpha", "new.git", "main"));
    assert(gitRepos.gitReposEntries == [
        GitReposEntry("/beta/", "b.git", ""),
        GitReposEntry("/alpha/", "new.git", "main"),
    ]);
}

/// add() refuses what parse() would refuse, and leaves entries unchanged.
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    immutable directory = testDirectory("gitRepos-add-invalid");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto gitRepos = fromText(directory, "/beta/ b.git\n");
    foreach (bad; [
        GitReposEntry("//alpha/", "a.git", ""),
        GitReposEntry("/", "a.git", ""),
        GitReposEntry("/alpha/", "", ""),
        GitReposEntry("/alpha/", "git@github.com:pflagerd//a.git", ""),
        GitReposEntry("/alpha/", "a.git", "feature//x"),
    ])
    {
        auto exception = collectException!GitReposException(gitRepos.add(bad));
        assert(exception && exception.msg.canFind("add(): "), bad.directory ~ " " ~ bad.url);
    }
    assert(gitRepos.gitReposEntries == [GitReposEntry("/beta/", "b.git", "")]);
}

/// remove() normalizes its argument, removes every match, and reports it.
unittest
{
    immutable directory = testDirectory("gitRepos-remove");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto gitRepos = fromText(directory, "/alpha/ a.git\n/beta/ b.git\n/alpha/ a2.git\n");
    assert(gitRepos.remove("alpha"));
    assert(gitRepos.gitReposEntries == [GitReposEntry("/beta/", "b.git", "")]);
    assert(!gitRepos.remove("/gamma/"));
    assert(gitRepos.gitReposEntries.length == 1);
}

// --- content() / write() ---------------------------------------------------

/// Sorted by directory, escaped, single spaces, branch omitted when empty.
unittest
{
    immutable directory = testDirectory("gitRepos-content");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto gitRepos = fromText(directory, "beta  b.git\tdev\n# comment\n\n/alpha/ a.git\n");
    gitRepos.add(GitReposEntry("My Repo", "/srv/git/my repo.git", ""));
    assert(gitRepos.content ==
        "/My%20Repo/ /srv/git/my%20repo.git\n"
        ~ "/alpha/ a.git\n"
        ~ "/beta/ b.git dev\n");
}

/// Duplicates are written, in their original order, for check() to report.
unittest
{
    immutable directory = testDirectory("gitRepos-content-duplicates");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto gitRepos = fromText(directory, "/beta/ second.git\n/alpha/ a.git\n/beta/ first.git\n");
    assert(gitRepos.content == "/alpha/ a.git\n/beta/ second.git\n/beta/ first.git\n");
}

/// No entries gives "".
unittest
{
    immutable directory = testDirectory("gitRepos-content-empty");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    assert(fromText(directory, "# only a comment\n").content == "");
}

/// Writes back to the path it was read from; an explicit path instead.
unittest
{
    import std.file : readText;

    immutable directory = testDirectory("gitRepos-write");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto gitRepos = fromText(directory, "/alpha/ a.git\n");
    gitRepos.add(GitReposEntry("/beta/", "b.git", ""));
    immutable other = buildPath(directory, "other");
    gitRepos.write(other);
    assert(other.readText == "/alpha/ a.git\n/beta/ b.git\n");
    assert(gitRepos.path.readText == "/alpha/ a.git\n");

    gitRepos.write();
    assert(gitRepos.path.readText == "/alpha/ a.git\n/beta/ b.git\n");
    assert(new GitRepos(gitRepos.path).gitReposEntries == gitRepos.gitReposEntries); // reads back the same
}

/// A missing file isn't created empty; an existing one is emptied, not deleted.
unittest
{
    import std.file : exists, readText;

    immutable directory = testDirectory("gitRepos-write-empty");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto missing = new GitRepos(buildPath(directory, "missing"));
    missing.write();
    assert(!missing.path.exists);

    auto gitRepos = fromText(directory, "/alpha/ a.git\n");
    assert(gitRepos.remove("/alpha/"));
    gitRepos.write();
    assert(gitRepos.path.exists && gitRepos.path.readText == "");
}

// --- round trip ------------------------------------------------------------

/// Files already in the tool's own format come back byte for byte, through
/// content() and through write().
unittest
{
    import std.file : read, write;

    immutable directory = testDirectory("gitRepos-round-trip");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable string[] files = [
        "",                                                              // empty file
        "/alpha/ git@github.com:pflagerd/alpha.git\n",                   // scp-like (ssh)
        "/alpha/ git@github.com:pflagerd/alpha.git\n/beta/ git@github.com:pflagerd/beta.git dev\n",
        "/alpha/ ssh://git@github.com/pflagerd/alpha.git feature/x\n",   // ssh:// and a slash in a branch
        "/local/ file:///srv/git/local.git\n/other/ /srv/git/other.git\n",
        "/tools/gamma/ git@github.com:pflagerd/gamma.git\n",             // nested path
        "/My%20Repo/ /srv/git/my%20repo.git 100%25\n",                   // escapes
        "/alpha/ first.git\n/alpha/ second.git\n",                       // duplicates, in order
    ];

    foreach (i, original; files)
    {
        immutable file = buildPath(directory, ".gitrepos");
        file.write(original);
        auto gitRepos = new GitRepos(file);
        assert(gitRepos.content == original, "content() differs for case " ~ i.to!string);

        gitRepos.write();
        assert(cast(string) file.read == original, "write() differs for case " ~ i.to!string);
    }
}

/// Where the tool deliberately changes a file on the way through.
unittest
{
    import std.file : write;

    immutable directory = testDirectory("gitRepos-round-trip-changes");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    string through(string text)
    {
        immutable file = buildPath(directory, ".gitrepos");
        file.write(text);
        return new GitRepos(file).content;
    }

    // Comments and blank lines are dropped.
    assert(through("# repos\n\n/alpha/ a.git\n") == "/alpha/ a.git\n");
    // Runs of whitespace become single spaces.
    assert(through("/alpha/   a.git\t\tdev\n") == "/alpha/ a.git dev\n");
    // Every slash form becomes /alpha/.
    assert(through("alpha a.git\n/beta b.git\ngamma/ c.git\n")
        == "/alpha/ a.git\n/beta/ b.git\n/gamma/ c.git\n");
    // Lines are sorted by directory.
    assert(through("/beta/ b.git\n/alpha/ a.git\n") == "/alpha/ a.git\n/beta/ b.git\n");
    // A final newline is added.
    assert(through("/alpha/ a.git") == "/alpha/ a.git\n");
    // A CRLF line's '\r' is dropped.
    assert(through("/alpha/ a.git\r\n") == "/alpha/ a.git\n");
    // Literal '%' that isn't one of the four escapes reads as text, and its
    // '%' is escaped on writing.
    assert(through("/foo%2Ebar/ a.git\n") == "/foo%252Ebar/ a.git\n");
    assert(through("/a/ a.git x%0ay\n") == "/a/ a.git x%250ay\n");
}

// --- check() ---------------------------------------------------------------

/// Sorted entries with distinct directories have no findings.
unittest
{
    immutable directory = testDirectory("gitRepos-check-clean");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    assert(fromText(directory, "/alpha/ a.git\n/beta/ b.git dev\n").check.length == 0);
    assert(fromText(directory, "").check.length == 0);
}

/// Unsorted entries: one fixable, whole-file finding.
unittest
{
    import std.algorithm.searching : canFind;

    immutable directory = testDirectory("gitRepos-check-unsorted");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto gitRepos = fromText(directory, "/beta/ b.git\n/alpha/ a.git\n");
    const findings = gitRepos.check;
    assert(findings.length == 1);
    assert(findings[0].directory == "" && findings[0].fixable);
    assert(findings[0].message.canFind(gitRepos.path) && findings[0].message.canFind("not sorted"));
}

/// Duplicates: one unfixable finding per directory, with the count, in
/// first-appearance order, after "not sorted".
unittest
{
    import std.algorithm.searching : canFind;

    immutable directory = testDirectory("gitRepos-check-duplicates");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto gitRepos = fromText(directory,
        "/gamma/ c.git\n/alpha/ a.git\n/gamma/ c2.git\n/alpha/ a2.git\n/alpha/ a3.git\n");
    const findings = gitRepos.check;
    assert(findings.length == 3);
    assert(findings[0].message.canFind("not sorted"));
    assert(findings[1].directory == "/gamma/" && !findings[1].fixable
        && findings[1].message.canFind("listed 2 times"));
    assert(findings[2].directory == "/alpha/" && !findings[2].fixable
        && findings[2].message.canFind("listed 3 times"));
    foreach (finding; findings)
    {
        assert(finding.message.canFind(gitRepos.path)); // every message names the file
    }
}

/// Sorted duplicates still report the duplicate, but not "not sorted".
unittest
{
    immutable directory = testDirectory("gitRepos-check-sorted-duplicates");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    const findings = fromText(directory, "/alpha/ a.git\n/alpha/ b.git\n").check;
    assert(findings.length == 1 && findings[0].directory == "/alpha/");
}
