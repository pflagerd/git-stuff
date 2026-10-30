/**
 * gitCloneDirectoryName: the directory name `git clone <url>` would create.
 *
 * A line-by-line port of git_url_basename() in git's dir.c:
 *   https://github.com/git/git/blob/master/dir.c
 * called from builtin/clone.c when no <directory> argument is given.
 * Character classes match git's own, not the C locale:
 *   - is_dir_sep() is '/' only on POSIX (git-compat-util.h)
 *   - isspace() is ' ', '\t', '\n', '\r' only (ctype.c, sane-ctype.h)
 *
 * Works on UTF-8 code units; every test is against ASCII bytes, so
 * multi-byte characters pass through untouched, as in the C original.
 */
module gitCloneDirectoryName;

class NoDirectoryNameException : Exception
{
    this(string url, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super("No directory name could be guessed from '" ~ url ~ "'",
              file, line);
    }
}

private bool isDirectorySeparator(char character) pure nothrow @nogc @safe
{
    return character == '/';
}

private bool gitIsSpace(char character) pure nothrow @nogc @safe
{
    return character == ' ' || character == '\t' || character == '\n' || character == '\r';
}

private bool gitIsDigit(char character) pure nothrow @nogc @safe
{
    return character >= '0' && character <= '9';
}

/**
 * Params:
 *   url      = repository argument exactly as given to `git clone`
 *   isBare   = true for `git clone --bare` / `--mirror` (appends ".git")
 *   isBundle = true when cloning from a local bundle file (strips ".bundle")
 * Throws: NoDirectoryNameException where git would die() with
 *         "No directory name could be guessed."
 */
string gitCloneDirectoryName(string url, bool isBare = false, bool isBundle = false) @safe
{
    import std.algorithm.searching : canFind, endsWith;
    import std.string : indexOf;

    // start and end bound the part of url still being considered.
    size_t start = 0;
    size_t end   = url.length;

    // Skip scheme.
    immutable schemeAt = url.indexOf("://");
    if (schemeAt >= 0)
    {
        start = schemeAt + 3;
    }

    // Skip authentication data, greedily up to the last '@' before the
    // first '/'.
    for (size_t position = start; position < end && !isDirectorySeparator(url[position]); ++position)
    {
        if (url[position] == '@')
        {
            start = position + 1;
        }
    }

    // Strip trailing slashes/whitespace, then a trailing "/.git".
    while (start < end && (isDirectorySeparator(url[end - 1]) || gitIsSpace(url[end - 1])))
    {
        --end;
    }
    if (end - start > 5 && isDirectorySeparator(url[end - 5]) && url[end - 4 .. end] == ".git")
    {
        end -= 5;
        while (start < end && isDirectorySeparator(url[end - 1]))
        {
            --end;
        }
    }

    // Strip a trailing ":port" when there is only a host (no '/').
    {
        immutable remaining = url[start .. end];
        if (!remaining.canFind('/') && remaining.canFind(':'))
        {
            size_t position = end;
            while (start < position && gitIsDigit(url[position - 1]))
            {
                --position;
            }
            if (start < position && url[position - 1] == ':')
            {
                end = position - 1;
            }
        }
    }

    // Last component; ':' also counts as a separator ("foo:bar.git" -> "bar").
    {
        size_t position = end;
        while (start < position && !isDirectorySeparator(url[position - 1]) && url[position - 1] != ':')
        {
            --position;
        }
        start = position;
    }

    // Strip ".bundle" or ".git".
    auto name = url[start .. end];
    immutable suffix = isBundle ? ".bundle" : ".git";
    if (name.endsWith(suffix))
    {
        name = name[0 .. $ - suffix.length];
    }

    if (name.length == 0 || name == "/")
    {
        throw new NoDirectoryNameException(url);
    }

    immutable directoryName = isBare ? name ~ ".git" : name;

    // Collapse runs of control characters and whitespace to one space,
    // and drop leading/trailing spaces.
    char[] collapsed;
    collapsed.reserve(directoryName.length);
    bool previousWasSpace = true;          // strips leading whitespace
    foreach (char character; directoryName)
    {
        if (character < 0x20)
        {
            character = ' ';
        }
        if (gitIsSpace(character))
        {
            if (previousWasSpace)
            {
                continue;
            }
            previousWasSpace = true;
        }
        else
        {
            previousWasSpace = false;
        }
        collapsed ~= character;
    }
    if (collapsed.length && previousWasSpace)
    {
        collapsed = collapsed[0 .. $ - 1];
    }
    return collapsed.idup;
}

/// Each expected name is what `git clone <url>` printed ("Cloning into
/// '<name>'...") with git 2.43.0, against hosts that don't exist.
@safe unittest
{
    immutable string[2][] cases = [
        ["git@nohost.invalid:pflagerd/blog-bootstrap.git", "blog-bootstrap"],
        ["ssh://pflagerd@nohost.invalid/p/pflagerd/kdenlive-b", "kdenlive-b"],
        ["https://nohost.invalid/git/git.git/", "git"],           // trailing slash
        ["https://nohost.invalid/a/repo/.git", "repo"],           // a /.git suffix
        ["https://nohost.invalid/x/.git", "x"],
        ["git@nohost.invalid:repo.git", "repo"],
        ["nohost.invalid:foo:bar.git", "bar"],                    // ':' separates too
        ["https://user:pw@nohost.invalid/x/My%20Repo.git", "My%20Repo"],
        ["https://nohost.invalid:8080", "nohost.invalid"],        // host only: port dropped
        ["ssh://nohost.invalid:22/", "nohost.invalid"],
        ["https://nohost.invalid/", "nohost.invalid"],
        ["ssh://nohost.invalid/x/foo.git//  ", "foo"],            // trailing slashes, spaces
        ["https://nohost.invalid/x/bar.bundle", "bar.bundle"],    // not a bundle clone
        ["https://nohost.invalid/x/ my   repo .git", "my repo"],  // spaces collapsed, trimmed
        ["https://nohost.invalid/x/a\tb.git", "a b"],             // a tab becomes a space
    ];
    foreach (testCase; cases)
    {
        assert(gitCloneDirectoryName(testCase[0]) == testCase[1], testCase[0]);
    }

    // git clone --bare: "Cloning into bare repository 'repo.git'...".
    assert(gitCloneDirectoryName("git@nohost.invalid:repo.git", true) == "repo.git");
}

/// Where git says "No directory name could be guessed", this throws.
@safe unittest
{
    import std.exception : assertThrown;

    assertThrown!NoDirectoryNameException(gitCloneDirectoryName("https://:@/"));
    assertThrown!NoDirectoryNameException(gitCloneDirectoryName("nohost.invalid:.git"));
}

/// A bundle clone strips ".bundle" instead of ".git". This one is read from
/// git's dir.c, not checked against git: a bundle needs a real file.
@safe unittest
{
    assert(gitCloneDirectoryName("/backups/project.bundle", false, true) == "project");
}
