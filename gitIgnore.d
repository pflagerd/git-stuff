/**
 * GitIgnore: one .gitignore file, split around the block of nested-repo
 * patterns that add-nested manages.
 *
 * Design: docs/nested-repos-design.md
 *
 *   .idea/                                            <- before
 *   # BEGIN nested repos (managed by add-nested)
 *   /alpha/                                           <- nested
 *   # END nested repos
 *   tmp/                                              <- after
 *
 * Only `nested` may change. `before` and `after` are kept exactly as read,
 * because order matters in .gitignore when `!` negation is used:
 * https://git-scm.com/docs/gitignore
 */
module gitIgnore;

import std.conv : to;
import std.file : exists;

import finding : Finding;
import textFile : readIfExists, splitFileLines, writeAtomically;

/// The marker lines. A line is a marker only if it is exactly this text.
enum beginMarker = "# BEGIN nested repos (managed by add-nested)";
/// ditto
enum endMarker = "# END nested repos";

/// Thrown when a .gitignore's managed block is malformed.
class GitIgnoreException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(message, file, line);
    }
}

class GitIgnore
{
    immutable string path;     /// where it was read from; write()'s default
    immutable string[] before; /// lines before the BEGIN marker, exactly as read
    string[] nested;           /// patterns inside the block, in file order
    immutable string[] after;  /// lines after the END marker, exactly as read
    immutable bool endsWithNewline; /// whether the file's last line ended in '\n'

    /**
     * Reads and parses `path`. A missing file is not an error: it reads as
     * empty, and she gets a .gitignore when it is first written.
     *
     * Throws: GitIgnoreException if the managed block is malformed.
     */
    this(string path = ".gitignore")
    {
        this.path = path;

        bool finalNewline;
        const lines = splitFileLines(readIfExists(path), finalNewline);
        endsWithNewline = finalNewline;
        auto parts = parse(lines);

        // immutable fields may only be assigned here, in the constructor
        // (https://dlang.org/spec/class.html#fields), which is why parsing
        // returns its result instead of assigning fields itself.
        before = parts.before.idup;
        nested = parts.nested;
        after = parts.after.idup;
    }

    /**
     * The file text write() would produce: `before`, then the managed block
     * with `nested` sorted and duplicates dropped, then `after`, joined with
     * '\n'.
     *
     * The block is left out when `nested` is empty, so removing the last
     * nested repo removes the block. When the block is the last thing in the
     * file, the file ends with '\n' (the END line is ours); otherwise the
     * original file's final newline, or lack of one, is kept.
     */
    string content() const @safe pure
    {
        import std.algorithm.sorting : sort;
        import std.array : join;

        string[] lines = before.dup;
        if (nested.length)
        {
            lines ~= beginMarker ~ sortedUnique(nested) ~ endMarker;
        }
        lines ~= after;

        if (lines.length == 0)
        {
            return "";
        }
        immutable blockIsLast = nested.length && after.length == 0;
        return lines.join("\n") ~ (endsWithNewline || blockIsLast ? "\n" : "");
    }

    /**
     * Problems with the managed block. Nothing is changed.
     *
     * - The block is not sorted (fixable: write() sorts it).
     * - An entry appears more than once (fixable: write() drops repeats).
     * - An entry is not of the form `/directory/` (not fixable: rewriting it
     *   would be a guess about what she meant).
     */
    Finding[] check() const @safe pure
    {
        import std.algorithm.sorting : isSorted;

        Finding[] findings;

        if (!nested.isSorted)
        {
            findings ~= Finding("", path ~ ": the managed block is not sorted", true);
        }

        bool[string] seen;
        foreach (entry; nested)
        {
            if (entry in seen)
            {
                findings ~= Finding(entry,
                    path ~ ": " ~ entry ~ " appears more than once in the managed block", true);
            }
            seen[entry] = true;

            if (!isDirectoryPattern(entry))
            {
                findings ~= Finding(entry,
                    path ~ ": '" ~ entry ~ "' in the managed block is not of the form /directory/",
                    false);
            }
        }

        return findings;
    }

    /// Whether `entry` looks like `/directory/` (or `/a/b/`): a leading and
    /// trailing slash with something between them, and no "//" anywhere.
    static bool isDirectoryPattern(string entry) @safe pure nothrow
    {
        import std.algorithm.searching : canFind;

        return entry.length > 2 && entry[0] == '/' && entry[$ - 1] == '/'
            && !entry.canFind("//");
    }

    /// A sorted copy of `entries` with repeats removed.
    static string[] sortedUnique(const string[] entries) @safe pure
    {
        import std.algorithm.iteration : uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;

        return entries.dup.sort.uniq.array;
    }

    /**
     * Writes content() to `toPath`, or by default to the path it was read
     * from, using textFile.writeAtomically (temporary file, then rename;
     * permissions kept). A file that doesn't exist and would be empty is not
     * created.
     */
    void write(string toPath = null) const
    {
        immutable target = toPath is null ? path : toPath;
        immutable text = content();
        if (text.length == 0 && !target.exists)
        {
            return;
        }
        writeAtomically(target, text);
    }

    /// The three parts of a parsed file.
    static struct Parts
    {
        string[] before;
        string[] nested;
        string[] after;
    }

    /**
     * Splits the lines of a .gitignore around the managed block.
     *
     * With no block, every line is in `before`. Blank lines inside the block
     * are skipped; every other line there is one nested pattern, kept as is.
     *
     * Throws: GitIgnoreException for an END without a BEGIN, a BEGIN without
     * an END, or more than one block. Line numbers in messages start at 1.
     */
    static Parts parse(const string[] lines) @safe pure
    {
        enum Where { before, inside, after }

        Parts parts;
        Where where = Where.before;
        size_t beginLine; // where the block opened, for the error message

        foreach (i, line; lines)
        {
            immutable lineNumber = i + 1;

            if (line == beginMarker)
            {
                if (where == Where.inside)
                {
                    throw new GitIgnoreException("line " ~ lineNumber.to!string
                        ~ ": BEGIN marker inside the block opened on line "
                        ~ beginLine.to!string);
                }
                if (where == Where.after)
                {
                    throw new GitIgnoreException("line " ~ lineNumber.to!string
                        ~ ": a second managed block; only one is allowed");
                }
                where = Where.inside;
                beginLine = lineNumber;
            }
            else if (line == endMarker)
            {
                if (where != Where.inside)
                {
                    throw new GitIgnoreException("line " ~ lineNumber.to!string
                        ~ ": END marker without a BEGIN marker before it");
                }
                where = Where.after;
            }
            else
            {
                final switch (where)
                {
                    case Where.before:
                        parts.before ~= line;
                        break;
                    case Where.inside:
                        if (line.length)
                        {
                            parts.nested ~= line;
                        }
                        break;
                    case Where.after:
                        parts.after ~= line;
                        break;
                }
            }
        }

        if (where == Where.inside)
        {
            throw new GitIgnoreException("line " ~ beginLine.to!string
                ~ ": BEGIN marker without an END marker after it");
        }

        return parts;
    }
}

// --- parse() -----------------------------------------------------------

/// No block: everything is `before`.
unittest
{
    auto p = GitIgnore.parse([".idea/", "*.o"]);
    assert(p.before == [".idea/", "*.o"]);
    assert(p.nested.length == 0);
    assert(p.after.length == 0);
}

/// Empty file.
unittest
{
    auto p = GitIgnore.parse([]);
    assert(p.before.length == 0 && p.nested.length == 0 && p.after.length == 0);
}

/// A block in the middle, with comments and blank lines around it kept.
unittest
{
    auto p = GitIgnore.parse([
        "# build output", "*.o", "",
        beginMarker, "/alpha/", "/beta/", endMarker,
        "", "tmp/",
    ]);
    assert(p.before == ["# build output", "*.o", ""]);
    assert(p.nested == ["/alpha/", "/beta/"]);
    assert(p.after == ["", "tmp/"]);
}

/// Blank lines inside the block are skipped; file order is kept (no sorting).
unittest
{
    auto p = GitIgnore.parse([beginMarker, "/beta/", "", "/alpha/", endMarker]);
    assert(p.nested == ["/beta/", "/alpha/"]);
}

/// An empty block.
unittest
{
    auto p = GitIgnore.parse(["*.o", beginMarker, endMarker]);
    assert(p.before == ["*.o"]);
    assert(p.nested.length == 0);
}

/// Only an exact marker line counts; near-misses are ordinary lines.
unittest
{
    auto p = GitIgnore.parse([beginMarker ~ " ", "# begin nested repos"]);
    assert(p.before == [beginMarker ~ " ", "# begin nested repos"]);
}

/// Malformed blocks throw, naming the line.
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    auto e = collectException!GitIgnoreException(
        GitIgnore.parse(["*.o", endMarker]));
    assert(e && e.msg.canFind("line 2") && e.msg.canFind("without a BEGIN"));

    e = collectException!GitIgnoreException(
        GitIgnore.parse([beginMarker, "/alpha/"]));
    assert(e && e.msg.canFind("line 1") && e.msg.canFind("without an END"));

    e = collectException!GitIgnoreException(
        GitIgnore.parse([beginMarker, beginMarker, endMarker]));
    assert(e && e.msg.canFind("line 2") && e.msg.canFind("inside the block"));

    e = collectException!GitIgnoreException(
        GitIgnore.parse([beginMarker, endMarker, beginMarker, endMarker]));
    assert(e && e.msg.canFind("line 3") && e.msg.canFind("second managed block"));
}

// --- test helpers --------------------------------------------------------

version (unittest)
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    import textFile : testDirectory;

    /// A GitIgnore read from a file holding `text`.
    private GitIgnore fromText(string directory, string text)
    {
        import std.file : write;

        immutable file = buildPath(directory, ".gitignore");
        file.write(text);
        return new GitIgnore(file);
    }
}

// --- constructor ---------------------------------------------------------

/// Reads a real file; a missing file reads as empty.
unittest
{
    immutable directory = testDirectory("constructor");
    scope (exit) directory.rmdirRecurse;

    immutable file = buildPath(directory, ".gitignore");
    auto missing = new GitIgnore(file);
    assert(missing.path == file);
    assert(missing.before.length == 0 && missing.nested.length == 0
        && missing.after.length == 0);
    assert(missing.endsWithNewline);

    auto g = fromText(directory,
        "*.o\n" ~ beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\ntmp/\n");
    assert(g.before == ["*.o"]);
    assert(g.nested == ["/alpha/"]);
    assert(g.after == ["tmp/"]);
    assert(g.endsWithNewline);

    assert(!fromText(directory, "*.o\ntmp/").endsWithNewline);
}

// --- content() -----------------------------------------------------------

/// The block is written sorted, between before and after.
unittest
{
    immutable directory = testDirectory("content-sorted");
    scope (exit) directory.rmdirRecurse;

    auto g = fromText(directory,
        "*.o\n" ~ beginMarker ~ "\n/beta/\n/alpha/\n" ~ endMarker ~ "\ntmp/\n");
    assert(g.content ==
        "*.o\n" ~ beginMarker ~ "\n/alpha/\n/beta/\n" ~ endMarker ~ "\ntmp/\n");
    assert(g.nested == ["/beta/", "/alpha/"]); // content() is const: no sorting in place
}

/// Adding to a file with no block appends the block, ending with '\n' even
/// when the original had no final newline.
unittest
{
    immutable directory = testDirectory("content-add");
    scope (exit) directory.rmdirRecurse;

    auto g = fromText(directory, "*.o\ntmp/");
    g.nested ~= "/gamma/";
    assert(g.content == "*.o\ntmp/\n" ~ beginMarker ~ "\n/gamma/\n" ~ endMarker ~ "\n");
}

/// With lines after the block, the original final newline (or none) is kept.
unittest
{
    immutable directory = testDirectory("content-newline");
    scope (exit) directory.rmdirRecurse;

    auto g = fromText(directory, beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\ntmp/");
    assert(g.content == beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\ntmp/");
}

/// An empty block is left out; nothing at all gives "".
unittest
{
    immutable directory = testDirectory("content-empty");
    scope (exit) directory.rmdirRecurse;

    auto g = fromText(directory, "*.o\n" ~ beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n");
    g.nested = [];
    assert(g.content == "*.o\n");

    assert(fromText(directory, "").content == "");
}

// --- write() -------------------------------------------------------------

/// Writes back to the path it was read from, leaving no temporary file.
unittest
{
    import std.algorithm.searching : count;
    import std.file : dirEntries, readText, SpanMode;

    immutable directory = testDirectory("write-default");
    scope (exit) directory.rmdirRecurse;

    auto g = fromText(directory, "*.o\n");
    g.nested ~= "/alpha/";
    g.write();
    assert(g.path.readText == "*.o\n" ~ beginMarker ~ "\n/alpha/\n" ~ endMarker ~ "\n");
    assert(dirEntries(directory, SpanMode.shallow).count == 1); // just .gitignore
}

/// An explicit path is written instead; the original is untouched.
unittest
{
    import std.file : readText;

    immutable directory = testDirectory("write-explicit");
    scope (exit) directory.rmdirRecurse;

    auto g = fromText(directory, "*.o\n");
    g.nested ~= "/alpha/";
    immutable other = buildPath(directory, "other");
    g.write(other);
    assert(other.readText == g.content);
    assert(g.path.readText == "*.o\n");
}

/// A missing file that would be empty is not created.
unittest
{
    immutable directory = testDirectory("write-nothing");
    scope (exit) directory.rmdirRecurse;

    auto g = new GitIgnore(buildPath(directory, ".gitignore"));
    g.write();
    assert(!g.path.exists);
}

// --- round trip ----------------------------------------------------------

/// Reading then writing reproduces these files byte for byte: any block is
/// already sorted and non-empty, and ends the file with '\n' if it is last.
unittest
{
    import std.file : read, write;

    immutable directory = testDirectory("round-trip");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    enum b = beginMarker, e = endMarker;
    immutable string[] files = [
        "",                                           // empty file
        "*.o\ntmp/\n",                                // no block
        "*.o\ntmp/",                                  // no final newline
        "*.o\r\ntmp/\r\n",                            // CRLF
        "\n\n# comment\n\n",                          // only blank lines and a comment
        "*.log\n!keep.log\n",                         // negation order kept
        "*.o\n" ~ b ~ "\n/alpha/\n/beta/\n" ~ e ~ "\n",                 // block last
        b ~ "\n/alpha/\n" ~ e ~ "\n",                                   // only a block
        "# top\n\n" ~ b ~ "\n/alpha/\n" ~ e ~ "\n\n# bottom\ntmp/\n",   // block in the middle
        "*.o\r\n" ~ b ~ "\n/alpha/\n" ~ e ~ "\ntmp/\r\n",               // CRLF around a block
        b ~ "\n/alpha/\n" ~ e ~ "\ntmp/",                               // after, no final newline
        "  spaced  \n\\#escaped\n\\!escaped\n",       // leading/trailing spaces, escapes
    ];

    foreach (i, original; files)
    {
        immutable file = buildPath(directory, ".gitignore");
        file.write(original);
        auto g = new GitIgnore(file);
        assert(g.content == original, "content() differs for case " ~ i.to!string);

        g.write();
        assert(cast(string) file.read == original, "write() differs for case " ~ i.to!string);
    }
}

/// Where the design deliberately changes a file on the way through.
unittest
{
    import std.file : write;

    immutable directory = testDirectory("round-trip-changes");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    enum b = beginMarker, e = endMarker;
    string through(string text)
    {
        immutable file = buildPath(directory, ".gitignore");
        file.write(text);
        return new GitIgnore(file).content;
    }

    // An unsorted block comes back sorted.
    assert(through(b ~ "\n/beta/\n/alpha/\n" ~ e ~ "\n") == b ~ "\n/alpha/\n/beta/\n" ~ e ~ "\n");
    // Repeated block entries are dropped.
    assert(through(b ~ "\n/beta/\n/alpha/\n/beta/\n" ~ e ~ "\n") == b ~ "\n/alpha/\n/beta/\n" ~ e ~ "\n");
    // Blank lines inside the block are dropped.
    assert(through(b ~ "\n/alpha/\n\n/beta/\n" ~ e ~ "\n") == b ~ "\n/alpha/\n/beta/\n" ~ e ~ "\n");
    // An empty block is removed.
    assert(through("*.o\n" ~ b ~ "\n" ~ e ~ "\ntmp/\n") == "*.o\ntmp/\n");
    // A block at the very end gains a final newline.
    assert(through("*.o\n" ~ b ~ "\n/alpha/\n" ~ e) == "*.o\n" ~ b ~ "\n/alpha/\n" ~ e ~ "\n");
}

// --- check() -------------------------------------------------------------

/// A sorted block of /directory/ entries has no findings.
unittest
{
    immutable directory = testDirectory("check-clean");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto g = fromText(directory, beginMarker ~ "\n/alpha/\n/tools/beta/\n" ~ endMarker ~ "\n");
    assert(g.check.length == 0);
    assert(fromText(directory, "*.o\n").check.length == 0); // no block at all
}

/// Each kind of problem is reported, with the right fixable flag.
unittest
{
    import std.algorithm.searching : canFind;

    immutable directory = testDirectory("check-problems");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    auto g = fromText(directory,
        beginMarker ~ "\n/beta/\n/alpha/\n/beta/\nalpha\n/gamma\n" ~ endMarker ~ "\n");
    const findings = g.check;
    assert(findings.length == 4);

    assert(findings[0].directory == "" && findings[0].fixable
        && findings[0].message.canFind("not sorted"));
    assert(findings[1].directory == "/beta/" && findings[1].fixable
        && findings[1].message.canFind("more than once"));
    assert(findings[2].directory == "alpha" && !findings[2].fixable
        && findings[2].message.canFind("not of the form /directory/"));
    assert(findings[3].directory == "/gamma" && !findings[3].fixable);

    foreach (f; findings)
    {
        assert(f.message.canFind(g.path)); // every message names the file
    }
}

/// isDirectoryPattern accepts /x/ forms only.
unittest
{
    assert(GitIgnore.isDirectoryPattern("/alpha/"));
    assert(GitIgnore.isDirectoryPattern("/a/b/"));
    assert(!GitIgnore.isDirectoryPattern("alpha"));
    assert(!GitIgnore.isDirectoryPattern("/alpha"));
    assert(!GitIgnore.isDirectoryPattern("alpha/"));
    assert(!GitIgnore.isDirectoryPattern("//"));
    assert(!GitIgnore.isDirectoryPattern("//alpha/"));       // too many slashes
    assert(!GitIgnore.isDirectoryPattern("/alpha//"));
    assert(!GitIgnore.isDirectoryPattern("/tools//alpha/"));
    assert(!GitIgnore.isDirectoryPattern("/alpha/\r")); // CRLF line: '\r' is part of it
}
