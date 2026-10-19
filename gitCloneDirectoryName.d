/**
 * gitCloneDirName: the directory name `git clone <url>` would create.
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

class NoDirNameException : Exception
{
    this(string url, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super("No directory name could be guessed from '" ~ url ~ "'",
              file, line);
    }
}

private bool isDirSep(char c) pure nothrow @nogc @safe { return c == '/'; }

private bool gitIsSpace(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

private bool gitIsDigit(char c) pure nothrow @nogc @safe
{
    return c >= '0' && c <= '9';
}

/**
 * Params:
 *   url      = repository argument exactly as given to `git clone`
 *   isBare   = true for `git clone --bare` / `--mirror` (appends ".git")
 *   isBundle = true when cloning from a local bundle file (strips ".bundle")
 * Throws: NoDirNameException where git would die() with
 *         "No directory name could be guessed."
 */
string gitCloneDirectoryName(string url, bool isBare = false, bool isBundle = false) @safe
{
    import std.algorithm.searching : canFind, endsWith;
    import std.string : indexOf;

    size_t start = 0;
    size_t end   = url.length;

    // Skip scheme.
    immutable schemeAt = url.indexOf("://");
    if (schemeAt >= 0)
        start = schemeAt + 3;

    // Skip authentication data, greedily up to the last '@' before the
    // first '/'.
    for (size_t p = start; p < end && !isDirSep(url[p]); ++p)
        if (url[p] == '@')
            start = p + 1;

    // Strip trailing slashes/whitespace, then a trailing "/.git".
    while (start < end && (isDirSep(url[end - 1]) || gitIsSpace(url[end - 1])))
        --end;
    if (end - start > 5 && isDirSep(url[end - 5]) && url[end - 4 .. end] == ".git")
    {
        end -= 5;
        while (start < end && isDirSep(url[end - 1]))
            --end;
    }

    // Strip a trailing ":port" when there is only a host (no '/').
    {
        auto s = url[start .. end];
        if (!s.canFind('/') && s.canFind(':'))
        {
            size_t p = end;
            while (start < p && gitIsDigit(url[p - 1]))
                --p;
            if (start < p && url[p - 1] == ':')
                end = p - 1;
        }
    }

    // Last component; ':' also counts as a separator ("foo:bar.git" -> "bar").
    {
        size_t p = end;
        while (start < p && !isDirSep(url[p - 1]) && url[p - 1] != ':')
            --p;
        start = p;
    }

    // Strip ".bundle" or ".git".
    auto name = url[start .. end];
    immutable suffix = isBundle ? ".bundle" : ".git";
    if (name.endsWith(suffix))
        name = name[0 .. $ - suffix.length];

    if (name.length == 0 || name == "/")
        throw new NoDirNameException(url);

    string dir = isBare ? name ~ ".git" : name;

    // Collapse runs of control characters and whitespace to one space,
    // and drop leading/trailing spaces.
    char[] outBuf;
    outBuf.reserve(dir.length);
    bool prevSpace = true;                 // strips leading whitespace
    foreach (char ch; dir)
    {
        if (ch < 0x20)
            ch = ' ';
        if (gitIsSpace(ch))
        {
            if (prevSpace)
                continue;
            prevSpace = true;
        }
        else
            prevSpace = false;
        outBuf ~= ch;
    }
    if (outBuf.length && prevSpace)
        outBuf = outBuf[0 .. $ - 1];
    return outBuf.idup;
}

// ///
// @safe unittest
// {
//     assert(gitCloneDirectoryName("git@github.com:pflagerd/blog-bootstrap.git") == "blog-bootstrap");
//     assert(gitCloneDirectoryName("ssh://pflagerd@git.code.sf.net/p/pflagerd/kdenlive-bc-memorial-project-b")
//            == "kdenlive-bc-memorial-project-b");
//     assert(gitCloneDirectoryName("https://github.com/git/git.git/") == "git");
//     assert(gitCloneDirectoryName("/srv/repos/proj/.git") == "proj");
//     assert(gitCloneDirectoryName("git@zax:repo.git", true) == "repo.git");
// }

// version (GitCloneDirMain)
// void main(string[] args)
// {
//     import std.stdio : stderr, writeln;
//     foreach (a; args[1 .. $])
//     {
//         try writeln(gitCloneDirName(a));
//         catch (NoDirNameException e) { stderr.writeln(e.msg); writeln("<die>"); }
//     }
// }
