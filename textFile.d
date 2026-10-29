/**
 * Reading and writing line-based text files the way GitIgnore and GitRepos
 * need: lines split on '\n' only, the final newline remembered, and writes
 * that never leave a truncated file.
 *
 * Design: docs/nested-repos-design.md
 */
module textFile;

import std.array : split;
import std.conv : to;
import std.file : exists, readText;

/**
 * The text of `path`, or "" if it doesn't exist.
 *
 * Throws: std.utf.UTFException if the file is not valid UTF-8, so a file
 * that can't be read correctly is never rewritten.
 */
string readIfExists(string path)
{
    return path.exists ? path.readText : "";
}

/**
 * Splits file text into lines on '\n' only, as git does; a '\r' stays part
 * of its line, so it is written back unchanged.
 *
 * `endsWithNewline` is set to whether the text ended in '\n'. Empty text
 * counts as ending in one, so a file created from nothing ends the usual way.
 */
string[] splitFileLines(string text, out bool endsWithNewline) @safe pure
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

/**
 * Writes `text` to `path` so that an interrupted write never leaves a
 * truncated file.
 *
 * The text goes to a temporary file in the same directory, which is then
 * renamed over `path`: POSIX rename() replaces the target in one step
 * (https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html).
 * An existing file's permission bits are kept.
 */
void writeAtomically(string path, string text)
{
    import std.conv : octal;
    import std.file : getAttributes, remove, rename, setAttributes, write;
    import std.path : baseName, buildPath, dirName;
    import std.process : thisProcessID;

    // Hidden, and in the same directory so rename() stays on one file system.
    immutable temporary = buildPath(path.dirName,
        "." ~ path.baseName ~ ".tmp." ~ thisProcessID.to!string);
    scope (failure)
    {
        if (temporary.exists)
        {
            temporary.remove;
        }
    }

    temporary.write(text);
    if (path.exists)
    {
        temporary.setAttributes(path.getAttributes & octal!7777);
    }
    rename(temporary, path);
}

// --- test helpers --------------------------------------------------------

version (unittest)
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    /// A fresh, empty directory for one test; remove it with rmdirRecurse.
    string testDirectory(string name)
    {
        immutable directory = buildPath(tempDir,
            "git-stuff-test-" ~ thisProcessID.to!string ~ "-" ~ name);
        if (directory.exists)
        {
            directory.rmdirRecurse;
        }
        directory.mkdirRecurse;
        return directory;
    }
}

// --- readIfExists() ------------------------------------------------------

/// A missing file reads as ""; an existing one as its text.
unittest
{
    import std.file : write;

    immutable directory = testDirectory("readIfExists");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable file = buildPath(directory, "f");
    assert(readIfExists(file) == "");
    file.write("a\n");
    assert(readIfExists(file) == "a\n");
}

/// Invalid UTF-8 is refused.
unittest
{
    import std.exception : assertThrown;
    import std.file : write;
    import std.utf : UTFException;

    immutable directory = testDirectory("readIfExists-utf8");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable file = buildPath(directory, "f");
    file.write(cast(const(ubyte)[]) "caf\xe9\n");
    assertThrown!UTFException(readIfExists(file));
}

// --- splitFileLines() ----------------------------------------------------

/// Final newline present, absent, and the empty file.
unittest
{
    bool nl;
    assert(splitFileLines("a\nb\n", nl) == ["a", "b"] && nl);
    assert(splitFileLines("a\nb", nl) == ["a", "b"] && !nl);
    assert(splitFileLines("", nl).length == 0 && nl);
}

/// Blank lines are kept, including a blank last line before the newline.
unittest
{
    bool nl;
    assert(splitFileLines("a\n\nb\n\n", nl) == ["a", "", "b", ""] && nl);
    assert(splitFileLines("\n", nl) == [""] && nl);
}

/// Only '\n' splits: '\r' stays in the line, so CRLF survives a round trip.
unittest
{
    bool nl;
    assert(splitFileLines("a\r\nb\r\n", nl) == ["a\r", "b\r"] && nl);
    assert(splitFileLines("a\rb\n", nl) == ["a\rb"] && nl);
}

// --- writeAtomically() ---------------------------------------------------

/// Creates or replaces the file, leaving no temporary file behind.
unittest
{
    import std.algorithm.searching : count;
    import std.file : dirEntries, readText, SpanMode;

    immutable directory = testDirectory("writeAtomically");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable file = buildPath(directory, "f");
    writeAtomically(file, "first\n");
    assert(file.readText == "first\n");
    writeAtomically(file, "second\n");
    assert(file.readText == "second\n");
    assert(dirEntries(directory, SpanMode.shallow).count == 1); // just f
}

/// An existing file's permission bits survive the rename.
unittest
{
    import std.conv : octal;
    import std.file : getAttributes, setAttributes, write;

    immutable directory = testDirectory("writeAtomically-mode");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable file = buildPath(directory, "f");
    file.write("old\n");
    file.setAttributes(octal!600);
    writeAtomically(file, "new\n");
    assert((file.getAttributes & octal!7777) == octal!600);
}

/// A rename that fails after the temporary file is written removes it.
/// Here the target is a non-empty directory, which rename() refuses to
/// replace with a file.
unittest
{
    import std.algorithm.searching : count;
    import std.exception : assertThrown;
    import std.file : dirEntries, FileException, mkdir, SpanMode, write;

    immutable directory = testDirectory("writeAtomically-failure");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable target = buildPath(directory, "target");
    target.mkdir;
    buildPath(target, "inside").write("x");

    assertThrown!FileException(writeAtomically(target, "x"));
    assert(dirEntries(directory, SpanMode.shallow).count == 1); // just target/
}
