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

import std.array : split;
import std.conv : to;
import std.file : exists, readText;

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
        const lines = splitFileLines(path.exists ? path.readText : "", finalNewline);
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
     * with `nested` sorted, then `after`, joined with '\n'.
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
            lines ~= beginMarker ~ nested.dup.sort.release ~ endMarker;
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
     * Writes content() to `toPath`, or by default to the path it was read
     * from.
     *
     * The text goes to a temporary file in the same directory, which is then
     * renamed over the target, so an interrupted write never leaves her a
     * truncated .gitignore: POSIX rename() replaces the target in one step
     * (https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html).
     * An existing target's permission bits are kept. A file that doesn't
     * exist and would be empty is not created.
     */
    void write(string toPath = null) const
    {
        import std.conv : octal;
        import std.file : getAttributes, remove, rename, setAttributes;
        import std.file : writeFile = write;
        import std.path : baseName, buildPath, dirName;
        import std.process : thisProcessID;

        immutable target = toPath is null ? path : toPath;
        immutable text = content();
        if (text.length == 0 && !target.exists)
        {
            return;
        }

        // Hidden, and in the same directory so rename() stays on one file system.
        immutable temporary = buildPath(target.dirName,
            "." ~ target.baseName ~ ".tmp." ~ thisProcessID.to!string);
        scope (failure)
        {
            if (temporary.exists)
            {
                temporary.remove;
            }
        }

        writeFile(temporary, text);
        if (target.exists)
        {
            temporary.setAttributes(target.getAttributes & octal!7777);
        }
        rename(temporary, target);
    }

    /**
     * Splits file text into lines on '\n' only, as git does; a '\r' stays
     * part of its line, so it is written back unchanged.
     *
     * `endsWithNewline` is set to whether the text ended in '\n'. Empty text
     * counts as ending in one, so a file created from nothing ends the usual
     * way.
     */
    static string[] splitFileLines(string text, out bool endsWithNewline) @safe pure
    {
        if (text.length == 0)
        {
            endsWithNewline = true;
            return [];
        }

        auto lines = text.split("\n");
        // "a\nb\n" splits to ["a", "b", ""]; the trailing "" marks the newline.
        endsWithNewline = lines[$ - 1].length == 0;
        if (endsWithNewline)
        {
            lines = lines[0 .. $ - 1];
        }
        return lines;
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

// --- splitFileLines() --------------------------------------------------

/// Final newline present, absent, and the empty file.
unittest
{
    bool nl;
    assert(GitIgnore.splitFileLines("a\nb\n", nl) == ["a", "b"] && nl);
    assert(GitIgnore.splitFileLines("a\nb", nl) == ["a", "b"] && !nl);
    assert(GitIgnore.splitFileLines("", nl).length == 0 && nl);
}

/// Blank lines are kept, including a blank last line before the newline.
unittest
{
    bool nl;
    assert(GitIgnore.splitFileLines("a\n\nb\n\n", nl) == ["a", "", "b", ""] && nl);
    assert(GitIgnore.splitFileLines("\n", nl) == [""] && nl);
}

/// Only '\n' splits: '\r' stays in the line, so CRLF survives a round trip.
unittest
{
    bool nl;
    assert(GitIgnore.splitFileLines("a\r\nb\r\n", nl) == ["a\r", "b\r"] && nl);
    assert(GitIgnore.splitFileLines("a\rb\n", nl) == ["a\rb"] && nl);
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
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    /// A fresh, empty directory for one test; remove it with rmdirRecurse.
    private string testDirectory(string name)
    {
        immutable directory = buildPath(tempDir,
            "gitIgnore-test-" ~ thisProcessID.to!string ~ "-" ~ name);
        if (directory.exists)
        {
            directory.rmdirRecurse;
        }
        directory.mkdirRecurse;
        return directory;
    }

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

/// An existing file's permission bits survive the rename.
unittest
{
    import std.conv : octal;
    import std.file : getAttributes, setAttributes;

    immutable directory = testDirectory("write-mode");
    scope (exit) directory.rmdirRecurse;

    auto g = fromText(directory, "*.o\n");
    g.path.setAttributes(octal!600);
    g.nested ~= "/alpha/";
    g.write();
    assert((g.path.getAttributes & octal!7777) == octal!600);
}
