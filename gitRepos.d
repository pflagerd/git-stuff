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

import textFile : readIfExists, splitFileLines;

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
    GitReposEntry[] entries; /// in file order, duplicates included

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
        entries = parse(splitFileLines(readIfExists(path), finalNewline));
    }

    /**
     * Parses the lines of a .gitrepos.
     *
     * Fields are separated by runs of whitespace, so older files with double
     * spaces or tabs still read. Each field is unescaped (see unescapeField),
     * and the directory is normalized to "/alpha/" form.
     *
     * Throws: GitReposException for a line with fewer than two or more than
     * three fields, an empty directory, or a directory containing "//".
     * Line numbers start at 1.
     */
    static GitReposEntry[] parse(const string[] lines) @safe pure
    {
        import std.array : split;
        import std.string : strip;

        GitReposEntry[] entries;

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

            import std.algorithm.searching : canFind;

            immutable directory = unescapeField(fields[0]);
            if (directory.canFind("//"))
            {
                throw new GitReposException("line " ~ lineNumber.to!string
                    ~ ": too many slashes in directory '" ~ directory ~ "'");
            }

            GitReposEntry entry;
            entry.directory = normalizeDirectory(directory);
            if (entry.directory.length == 0)
            {
                throw new GitReposException("line " ~ lineNumber.to!string
                    ~ ": empty directory");
            }
            entry.url = unescapeField(fields[1]);
            if (fields.length == 3)
            {
                entry.branch = unescapeField(fields[2]);
            }
            entries ~= entry;
        }

        return entries;
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
    foreach (s; ["/alpha/", "git@github.com:pflagerd/alpha.git",
                 "https://github.com/pflagerd/alpha.git", "dev"])
    {
        assert(escapeField(s) == s);
        assert(unescapeField(s) == s);
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
    foreach (s; ["", "plain", "My Repo", "100%", "%20", "%2520", "a\tb\nc",
                 "foo%2Ebar", "% %25 %%", "trailing%"])
    {
        assert(unescapeField(escapeField(s)) == s, s);
    }
}

// --- normalizeDirectory() ------------------------------------------------

/// Every slash form becomes /alpha/; nested paths keep their inner slash.
unittest
{
    foreach (s; ["alpha", "/alpha", "alpha/", "/alpha/"])
    {
        assert(GitRepos.normalizeDirectory(s) == "/alpha/", s);
    }
    assert(GitRepos.normalizeDirectory("tools/alpha") == "/tools/alpha/");
    assert(GitRepos.normalizeDirectory("/") == "");
    assert(GitRepos.normalizeDirectory("") == "");
}

// --- parse() ---------------------------------------------------------------

/// Two and three fields; the directory is normalized.
unittest
{
    auto e = GitRepos.parse([
        "/alpha/ git@github.com:pflagerd/alpha.git",
        "beta git@github.com:pflagerd/beta.git dev",
    ]);
    assert(e.length == 2);
    assert(e[0] == GitReposEntry("/alpha/", "git@github.com:pflagerd/alpha.git", ""));
    assert(e[1] == GitReposEntry("/beta/", "git@github.com:pflagerd/beta.git", "dev"));
}

/// Blank lines and comments are skipped; file order and duplicates are kept.
unittest
{
    auto e = GitRepos.parse([
        "# nested repos", "",
        "/beta/ b.git", "   ", "  # indented comment",
        "/alpha/ a.git", "/beta/ other.git",
    ]);
    assert(e.length == 3);
    assert(e[0].directory == "/beta/" && e[1].directory == "/alpha/");
    assert(e[2] == GitReposEntry("/beta/", "other.git", ""));
}

/// Runs of spaces or tabs separate fields; a CRLF line's '\r' is dropped.
unittest
{
    auto e = GitRepos.parse(["/alpha/  a.git\tdev", "/beta/ b.git\r"]);
    assert(e[0] == GitReposEntry("/alpha/", "a.git", "dev"));
    assert(e[1] == GitReposEntry("/beta/", "b.git", ""));
}

/// Escaped fields are decoded.
unittest
{
    auto e = GitRepos.parse(["/My%20Repo/ /srv/git/my%20repo.git my%25branch"]);
    assert(e[0] == GitReposEntry("/My Repo/", "/srv/git/my repo.git", "my%branch"));
}

/// Wrong field counts and an empty directory throw, naming the line.
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    auto x = collectException!GitReposException(GitRepos.parse(["# c", "/alpha/"]));
    assert(x && x.msg.canFind("line 2") && x.msg.canFind("1 field"));

    x = collectException!GitReposException(GitRepos.parse(["/a/ a.git dev extra"]));
    assert(x && x.msg.canFind("line 1") && x.msg.canFind("4 field"));

    x = collectException!GitReposException(GitRepos.parse(["/ a.git"]));
    assert(x && x.msg.canFind("line 1") && x.msg.canFind("empty directory"));
}

/// A doubled slash anywhere in the directory throws, naming the line.
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    foreach (directory; ["//alpha/", "/alpha//", "/tools//alpha/", "//"])
    {
        auto x = collectException!GitReposException(
            GitRepos.parse(["/ok/ ok.git", directory ~ " a.git"]));
        assert(x && x.msg.canFind("line 2") && x.msg.canFind("too many slashes"), directory);
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
    assert(missing.path == file && missing.entries.length == 0);

    file.write("/alpha/ git@github.com:pflagerd/alpha.git\n/beta/ b.git dev\n");
    auto g = new GitRepos(file);
    assert(g.entries == [
        GitReposEntry("/alpha/", "git@github.com:pflagerd/alpha.git", ""),
        GitReposEntry("/beta/", "b.git", "dev"),
    ]);
}
