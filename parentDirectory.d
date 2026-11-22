/**
 * ParentDirectory: a directory holding nested repos, with its .gitignore and
 * .gitrepos. It is the only place that works with both files, so they can
 * be kept in step. The directory need not be a git repository itself.
 *
 * Design: docs/nested-repos-design.md
 */
module parentDirectory;

import core.attribute : mustuse;
import std.typecons : Flag, No, Yes;

import finding : Finding;
import gitIgnore : GitIgnore;
import gitRepos : GitRepos, GitReposEntry;
// nestedCommon imports this module too. D allows such a cycle; it only
// refuses one between modules that both have static constructors, and
// neither has any. https://dlang.org/spec/module.html#order_of_static_ctor
import nestedCommon : entryFor, EntryOutcome, EntryResult;

/// What ParentDirectory.checkRepository found at a path.
enum RepositoryOutcome
{
    repository,       /// the top level of its own git repository: a nested repo
    missing,          /// nothing there
    notDirectory,     /// a file, not a directory
    notGitRepository, /// a directory git doesn't see as a repository
    insideRepository, /// a plain directory inside some other repository
}

/// checkRepository's result: what was found, and a message for her to read.
/// Design: docs/result-types.md
@mustuse struct RepositoryResult
{
    RepositoryOutcome outcome;
    string message; /// "" when outcome is repository
}

/**
 * A nested repo that its nearest enclosing parent's .gitrepos doesn't list
 * (checkDisk() item 6). That parent is the nearest directory above it that
 * is a git repository or has a .gitrepos; the -C directory always counts.
 * Without -r it is always the -C directory.
 */
private struct UnlistedRepository
{
    string directory;        /// "/tools/alpha/" form, relative to the -C directory
    string onDisk;           /// its path, for messages
    bool parentIsTop;        /// whether its nearest enclosing parent is the -C directory
    string parentOnDisk;     /// that parent's path
    string relativeToParent; /// "/alpha/" form, relative to that parent: what its .gitrepos would list
    /// Only when parentIsTop: what `add-nested <dir>` would record (found:
    /// registerUnlisted() can register it), or why not. Otherwise it is
    /// left at its .init, which reads as found, so check parentIsTop first.
    EntryResult entryResult;
}

class ParentDirectory
{
    immutable string directory; /// the parent directory, as given

    // private: in D, private means private to this module, and this module
    // holds only ParentDirectory, so only its methods can replace these.
    // Commands go through add(), remove() and fix(), which keep both files
    // in step. https://dlang.org/spec/attribute.html#visibility_attributes
    // The leading _ marks the field behind the read-only property of the
    // same name below; D won't let a field and a method share a name.
    private GitIgnore _gitIgnore;
    private GitRepos _gitRepos;

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
        _gitIgnore = new GitIgnore(buildPath(directory, ".gitignore"));
        _gitRepos = new GitRepos(buildPath(directory, ".gitrepos"));
    }

    /// Read-only views of the two files.
    const(GitIgnore) gitIgnore() const @safe pure nothrow @nogc
    {
        return _gitIgnore;
    }

    /// ditto
    const(GitRepos) gitRepos() const @safe pure nothrow @nogc
    {
        return _gitRepos;
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

        _gitRepos.add(gitReposEntry); // may throw; nothing changed yet if it does
        immutable pattern = GitRepos.normalizeDirectory(gitReposEntry.directory);
        if (!_gitIgnore.nested.canFind(pattern))
        {
            _gitIgnore.nested ~= pattern;
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
        immutable fromRepos = _gitRepos.remove(directory);

        immutable before = _gitIgnore.nested.length;
        _gitIgnore.nested = _gitIgnore.nested.filter!(existingPattern => existingPattern != pattern).array;
        immutable fromIgnore = _gitIgnore.nested.length != before;

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

        Finding[] findings = _gitIgnore.check() ~ _gitRepos.check();

        bool[string] inRepos;
        string[] reposOrder; // distinct .gitrepos directories, in file order
        foreach (gitReposEntry; _gitRepos.gitReposEntries)
        {
            if (gitReposEntry.directory !in inRepos)
            {
                reposOrder ~= gitReposEntry.directory;
            }
            inRepos[gitReposEntry.directory] = true;
        }

        bool[string] loose;
        foreach (line; _gitIgnore.before ~ _gitIgnore.after)
        {
            immutable directory = looseDirectory(line);
            if (directory.length && directory in inRepos && directory !in loose)
            {
                loose[directory] = true;
                findings ~= Finding(directory, _gitIgnore.path ~ ": '" ~ line
                    ~ "' names nested repo " ~ directory
                    ~ " outside the managed block", true);
            }
        }

        foreach (directory; reposOrder)
        {
            if (!_gitIgnore.nested.canFind(directory) && directory !in loose)
            {
                findings ~= Finding(directory, _gitRepos.path ~ ": " ~ directory
                    ~ " is not in the managed block of " ~ _gitIgnore.path, true);
            }
        }

        bool[string] reported;
        foreach (pattern; _gitIgnore.nested)
        {
            if (GitIgnore.isDirectoryPattern(pattern) && pattern !in inRepos
                && pattern !in reported)
            {
                reported[pattern] = true;
                findings ~= Finding(pattern, _gitIgnore.path ~ ": " ~ pattern
                    ~ " is in the managed block but not in " ~ _gitRepos.path, false);
            }
        }

        return findings;
    }

    /**
     * Problems on disk: with the nested repos .gitrepos lists, and nested
     * repos it doesn't list. Only item 6 can be fixable: a missing clone is
     * pull-nested's job, and items 1-5 need her judgement. check() never
     * touches the disk; this always does. Nothing is changed.
     *
     * For each distinct directory in .gitrepos, in file order, the first
     * problem found:
     * 1. it does not exist (#6);
     * 2. it is not a directory;
     * 3. `git -C <dir> rev-parse --show-toplevel` fails: not a git
     *    repository (git's own message is included);
     * 4. git names a different top level, compared after resolving symlinks
     *    on both sides: it is inside another repository, not one itself;
     * 5. no remote's url (`remote.<name>.url`, as stored, before any
     *    insteadOf rewriting) equals the url in .gitrepos.
     *
     * Then, for the parent's direct entries, in name order (#15):
     * 6. a nested repo (checkRepository's `repository`) that .gitrepos
     *    doesn't list. Skipped, and so never reported: names starting with
     *    "." (.git included), and directories that any .gitignore line
     *    names, inside the managed block or outside it, in any slash form
     *    (looseDirectory()), so a hand-written `/household/` keeps a
     *    private repo quiet. Symbolic links are followed, so a link to a
     *    repo is reported; files and dangling links are not. Only direct
     *    entries are looked at, unless `recursive` is Yes.recursive (-r):
     *    then the walk goes deeper, and a repository is judged against
     *    its nearest enclosing parent (see unlistedRepositoriesRecursive()).
     *    Fixable when that parent is this directory and entryFor()
     *    works out its entry as `add-nested <dir>` would (registerUnlisted()
     *    does the fixing, not fix()); not fixable when it has no origin
     *    remote, a detached HEAD, or an entry .gitrepos would refuse, and
     *    the message says which add-nested option she needs, nor when the
     *    parent is another directory, and the message says to run
     *    check-nested there.
     *
     * Git is run with an argument list, never through a shell, so names
     * with spaces are safe.
     */
    Finding[] checkDisk(Flag!"recursive" recursive = No.recursive) const
    {
        import std.path : buildPath;

        Finding[] findings;
        bool[string] seen; // the distinct .gitrepos directories, "/alpha/" form

        foreach (gitReposEntry; _gitRepos.gitReposEntries)
        {
            if (gitReposEntry.directory in seen)
            {
                continue;
            }
            seen[gitReposEntry.directory] = true;

            immutable onDisk = buildPath(directory, gitReposEntry.directory[1 .. $ - 1]);
            const repositoryResult = checkRepository(gitReposEntry.directory, onDisk);
            with (RepositoryOutcome) final switch (repositoryResult.outcome)
            {
            case repository:
                if (!hasRemoteUrl(onDisk, gitReposEntry.url))
                {
                    findings ~= Finding(gitReposEntry.directory, onDisk ~ ": no remote of "
                        ~ gitReposEntry.directory ~ " has url " ~ gitReposEntry.url, false);
                }
                break;
            case missing, notDirectory, notGitRepository, insideRepository:
                findings ~= Finding(gitReposEntry.directory, onDisk ~ ": " ~ repositoryResult.message, false);
                break;
            }
        }

        return findings ~ unlistedFindings(seen, recursive);
    }

    /**
     * checkDisk()'s item 6: a finding for each unlisted nested repo (see
     * unlistedRepositories(), and unlistedRepositoriesRecursive() for -r),
     * fixable when its nearest enclosing parent is the -C directory and
     * entryFor() can work out its entry, so registerUnlisted() would
     * register it. Otherwise the message says what she needs to run.
     */
    private Finding[] unlistedFindings(const bool[string] listed, Flag!"recursive" recursive) const
    {
        import std.algorithm.searching : canFind;
        import std.path : buildPath;

        Finding[] findings;
        const unlistedRepositories = recursive
            ? unlistedRepositoriesRecursive(listed, findings)
            : this.unlistedRepositories(listed, findings); // this.: the method, not the variable
        foreach (unlistedRepository; unlistedRepositories)
        {
            // the name add-nested takes, relative to the parent: "/tools/alpha/" -> "tools/alpha"
            immutable name = unlistedRepository.relativeToParent[1 .. $ - 1];
            immutable notListed = unlistedRepository.onDisk ~ ": " ~ unlistedRepository.relativeToParent
                ~ " is a git repository but is not listed in "
                ~ buildPath(unlistedRepository.parentOnDisk, ".gitrepos");
            if (!unlistedRepository.parentIsTop)
            {
                // Its own parent's business (proposal, answer 3b). Below a
                // direct child of that parent only -r finds it, so say -r.
                findings ~= Finding(unlistedRepository.directory, notListed ~ "; run check-nested -C "
                    ~ unlistedRepository.parentOnDisk ~ (name.canFind('/') ? " -r" : "") ~ " --fix", false);
                continue;
            }
            const entryResult = unlistedRepository.entryResult;
            with (EntryOutcome) final switch (entryResult.outcome)
            {
            case found:
                findings ~= Finding(unlistedRepository.directory, notListed, true);
                break;
            case noOrigin:
                findings ~= Finding(unlistedRepository.directory, notListed
                    ~ "; it has no origin remote, so add it with add-nested --url <url> " ~ name, false);
                break;
            case detachedHead:
                findings ~= Finding(unlistedRepository.directory, notListed
                    ~ "; it has no current branch (detached HEAD), so add it with"
                    ~ " add-nested --branch <branch> " ~ name, false);
                break;
            case badDirectoryArgument, notRepository, invalidEntry:
                findings ~= Finding(unlistedRepository.directory, notListed
                    ~ "; add-nested can't register it as it is: " ~ entryResult.message, false);
                break;
            }
        }
        return findings;
    }

    /**
     * Registers, with add(), each nested repo that checkDisk() item 6 marks
     * fixable, with the entry entryFor() works out for it: the url of
     * `origin`, and the branch by add-nested's rule, as `add-nested <dir>`
     * would record it. The others are left for checkDisk() to report.
     *
     * Unlike fix(), this reads the disk (local git state only, never the
     * network), so only check-nested --fix calls it; the other commands'
     * --fix stay in memory. Nothing is written until write().
     *
     * Returns: the entries registered, in name order.
     */
    GitReposEntry[] registerUnlisted(Flag!"recursive" recursive = No.recursive)
    {
        bool[string] listed; // the .gitrepos directories, "/alpha/" form
        foreach (gitReposEntry; _gitRepos.gitReposEntries)
        {
            listed[gitReposEntry.directory] = true;
        }

        Finding[] listingFindings; // a directory that can't be listed; checkDisk() reports it
        GitReposEntry[] gitReposEntries;
        const unlistedRepositories = recursive
            ? unlistedRepositoriesRecursive(listed, listingFindings)
            : this.unlistedRepositories(listed, listingFindings);
        foreach (unlistedRepository; unlistedRepositories)
        {
            if (!unlistedRepository.parentIsTop)
            {
                continue; // its own parent's business: one run never writes another's files
            }
            with (EntryOutcome) final switch (unlistedRepository.entryResult.outcome)
            {
            case found:
                add(unlistedRepository.entryResult.gitReposEntry);
                gitReposEntries ~= unlistedRepository.entryResult.gitReposEntry;
                break;
            case badDirectoryArgument, notRepository, noOrigin, detachedHead, invalidEntry:
                break; // not fixable; checkDisk() reports it
            }
        }
        return gitReposEntries;
    }

    /**
     * The direct entries of the parent that are nested repos but are
     * neither in `listed` (the .gitrepos directories) nor named by a
     * .gitignore line, in name order, each with what entryFor() made of
     * it. A problem listing the directory is appended to `findings`.
     */
    private UnlistedRepository[] unlistedRepositories(const bool[string] listed,
        ref Finding[] findings) const
    {
        import std.algorithm.iteration : map;
        import std.algorithm.sorting : sort;
        import std.array : array;
        import std.file : dirEntries, exists, FileException, isDir, SpanMode;
        import std.path : baseName, buildPath;

        bool[string] named; // directories any .gitignore line names, "/alpha/" form
        foreach (line; _gitIgnore.before ~ _gitIgnore.nested ~ _gitIgnore.after)
        {
            immutable namedDirectory = looseDirectory(line);
            if (namedDirectory.length)
            {
                named[namedDirectory] = true;
            }
        }

        // A parent that doesn't exist has no entries; items 1-5 already
        // report every listed repo in it as missing.
        if (!directory.exists || !directory.isDir)
        {
            return [];
        }
        string[] names;
        try
        {
            // shallow: direct entries only. dirEntries gives them in no
            // particular order, so they are sorted for stable output.
            names = dirEntries(directory, SpanMode.shallow)
                .map!(dirEntry => dirEntry.name.baseName).array;
        }
        catch (FileException exception)
        {
            findings ~= Finding("", directory ~ ": could not list it to look for unlisted nested repos ("
                ~ exception.msg ~ ")", false);
            return [];
        }
        names.sort();

        UnlistedRepository[] unlistedRepositories;
        foreach (name; names)
        {
            if (name[0] == '.')
            {
                continue;
            }
            immutable nestedDirectory = "/" ~ name ~ "/";
            if (nestedDirectory in listed || nestedDirectory in named)
            {
                continue;
            }
            // Only directories, following symbolic links. isDir follows them
            // (stat(2)) and throws for a dangling one, which is skipped too.
            // checkRepository can't be left to do this: exists() doesn't
            // follow links (lstat(2)), so it would call isDir and throw.
            immutable onDisk = buildPath(directory, name);
            bool isDirectory;
            try
            {
                isDirectory = onDisk.isDir;
            }
            catch (FileException)
            {
                isDirectory = false;
            }
            if (!isDirectory)
            {
                continue;
            }
            const repositoryResult = checkRepository(nestedDirectory, onDisk);
            with (RepositoryOutcome) final switch (repositoryResult.outcome)
            {
            case repository:
                // No --branch or --url: what `add-nested <name>` would record.
                unlistedRepositories ~= UnlistedRepository(nestedDirectory, onDisk, true,
                    directory, nestedDirectory, entryFor(directory, nestedDirectory, "", ""));
                break;
            case missing, notDirectory, notGitRepository, insideRepository:
                break; // not a nested repo, so nothing to register
            }
        }
        return unlistedRepositories;
    }

    /**
     * With -r: like unlistedRepositories(), but the walk goes below the
     * direct entries, depth first, in name order at each level, so a
     * repository comes just before what is inside it. Docs: the proposal's
     * answers 1b, 3b and 4, and "Rules that follow".
     *
     * - It doesn't stop at repositories: it walks into every directory
     *   except those whose name starts with "." and those that a line of
     *   any .gitignore it meets names (looseDirectory()'s rule, each line
     *   relative to its own .gitignore's folder). The managed block names
     *   every listed repo, so listed repos aren't walked into.
     * - It follows symbolic links, and never enters a directory twice: it
     *   remembers each one's resolved path (realpath(3)), so a link loop
     *   ends. A directory reached twice is walked the first way, in name
     *   order.
     * - A repository is reported when its nearest enclosing parent's
     *   .gitrepos doesn't list it. That parent is the nearest directory
     *   above it that is a git repository or has a .gitrepos, or else the
     *   -C directory. Only those whose parent is the -C directory get an
     *   entryFor() result, and so can be fixable.
     * - Which directories are repositories: a direct entry is asked with
     *   checkRepository(), as in the default mode, so -r reports at least
     *   what the default does. Deeper, only a directory with a ".git"
     *   entry is asked, so there is a git process per candidate, not per
     *   directory.
     * - A directory it can't list, or a .gitrepos or .gitignore it can't
     *   read, is a finding appended to `findings`, and the walk goes on.
     */
    private UnlistedRepository[] unlistedRepositoriesRecursive(const bool[string] listed,
        ref Finding[] findings) const
    {
        import std.file : exists, FileException, isDir;

        // A parent that doesn't exist has no entries (see unlistedRepositories()).
        if (!directory.exists || !directory.isDir)
        {
            return [];
        }
        Listing listing;
        try
        {
            listing = listDirectory(directory);
        }
        catch (FileException exception)
        {
            findings ~= Finding("", directory ~ ": could not list it to look for unlisted nested repos ("
                ~ exception.msg ~ ")", false);
            return [];
        }

        bool[string] named; // directories .gitignore lines name, "/tools/alpha/" form, relative to -C
        addNamed(_gitIgnore.before ~ _gitIgnore.nested ~ _gitIgnore.after, "", named);
        bool[string] visited = [resolvePath(directory): true]; // a set: only the keys matter
        UnlistedRepository[] unlistedRepositories;
        walk(directory, "", listing, EnclosingParent(directory, "", true, listed.dup, true),
            named, visited, unlistedRepositories, findings);
        return unlistedRepositories;
    }

    /// The nearest enclosing parent, as the recursive walk carries it down.
    private static struct EnclosingParent
    {
        string onDisk;              /// its path
        string prefix;              /// its path relative to the -C directory, "/tools" form; "" for -C itself
        bool isTop;                 /// whether it is the -C directory
        const(bool)[string] listed; /// its .gitrepos directories, "/alpha/" form (a set)
        bool readable;              /// false when its .gitrepos couldn't be read, so what it lists is unknown
    }

    /// One directory's entries, as the recursive walk needs them.
    private static struct Listing
    {
        string[] directories; /// names of subdirectories not starting with ".", links followed, sorted
        bool hasGit;          /// a ".git" entry (a directory, or a file as in a linked worktree)
        bool hasGitRepos;     /// a ".gitrepos" entry
        bool hasGitIgnore;    /// a ".gitignore" entry
    }

    /**
     * Lists `onDisk` once: what the walk needs to know without running git.
     *
     * Throws: FileException if it can't be listed (for example, no
     * permission to read it).
     */
    private static Listing listDirectory(string onDisk)
    {
        import std.algorithm.sorting : sort;
        import std.file : dirEntries, FileException, SpanMode;
        import std.path : baseName;

        Listing listing;
        foreach (dirEntry; dirEntries(onDisk, SpanMode.shallow))
        {
            immutable name = dirEntry.name.baseName;
            if (name == ".git")
            {
                listing.hasGit = true;
            }
            else if (name == ".gitrepos")
            {
                listing.hasGitRepos = true;
            }
            else if (name == ".gitignore")
            {
                listing.hasGitIgnore = true;
            }
            if (name[0] == '.')
            {
                continue;
            }
            // DirEntry.isDir follows a symbolic link (stat(2)); for a
            // dangling one it is false. The try is for anything else stat
            // can refuse.
            bool isDirectory;
            try
            {
                isDirectory = dirEntry.isDir;
            }
            catch (FileException)
            {
                isDirectory = false;
            }
            if (isDirectory)
            {
                listing.directories ~= name;
            }
        }
        listing.directories.sort();
        return listing;
    }

    /// Adds to `named` the directory each of `lines` names (looseDirectory()),
    /// relative to the folder with prefix `prefix` ("" for the -C directory).
    private static void addNamed(const string[] lines, string prefix, ref bool[string] named)
    {
        foreach (line; lines)
        {
            immutable namedDirectory = looseDirectory(line);
            if (namedDirectory.length)
            {
                named[prefix ~ namedDirectory] = true;
            }
        }
    }

    /**
     * The recursive walk below `onDisk`, whose entries are `listing` and
     * whose prefix is `prefix` (see EnclosingParent). Recursion, not an
     * explicit stack: the depth is the depth of the tree, and each call's
     * enclosing parent then simply goes out of scope on the way back up.
     */
    private void walk(string onDisk, string prefix, const Listing listing,
        EnclosingParent enclosingParent, ref bool[string] named, ref bool[string] visited,
        ref UnlistedRepository[] unlistedRepositories, ref Finding[] findings) const
    {
        import std.file : FileException;
        import std.path : buildPath;

        foreach (name; listing.directories)
        {
            immutable childPrefix = prefix ~ "/" ~ name;
            immutable childDirectory = childPrefix ~ "/"; // relative to -C, "/tools/alpha/" form
            if (childDirectory in named)
            {
                continue;
            }
            immutable childOnDisk = buildPath(onDisk, name);
            immutable resolved = resolvePath(childOnDisk);
            if (resolved in visited)
            {
                continue;
            }
            visited[resolved] = true;

            Listing childListing;
            try
            {
                childListing = listDirectory(childOnDisk);
            }
            catch (FileException exception)
            {
                findings ~= Finding(childDirectory, childOnDisk
                    ~ ": could not list it to look for unlisted nested repos (" ~ exception.msg ~ ")", false);
                continue;
            }

            bool isRepository;
            if (prefix.length == 0 || childListing.hasGit) // a direct entry, or a candidate
            {
                const repositoryResult = checkRepository(childDirectory, childOnDisk);
                with (RepositoryOutcome) final switch (repositoryResult.outcome)
                {
                case repository:
                    isRepository = true;
                    break;
                case missing, notDirectory, notGitRepository, insideRepository:
                    break;
                }
            }

            if (isRepository && enclosingParent.readable)
            {
                // "/tools/alpha/" less the parent's prefix "/tools": "/alpha/"
                immutable relativeToParent = childDirectory[enclosingParent.prefix.length .. $];
                if (relativeToParent !in enclosingParent.listed)
                {
                    // No --branch or --url: what `add-nested <dir>` would record.
                    unlistedRepositories ~= UnlistedRepository(childDirectory, childOnDisk,
                        enclosingParent.isTop, enclosingParent.onDisk, relativeToParent,
                        enclosingParent.isTop ? entryFor(directory, relativeToParent, "", "") : EntryResult.init);
                }
            }

            if (childListing.hasGitIgnore)
            {
                addNamedIn(childOnDisk, childPrefix, named, findings);
            }
            walk(childOnDisk, childPrefix, childListing,
                isRepository || childListing.hasGitRepos
                    ? enclosingParentAt(childOnDisk, childPrefix, childListing.hasGitRepos, findings)
                    : enclosingParent,
                named, visited, unlistedRepositories, findings);
        }
    }

    /// `onDisk` as the nearest enclosing parent of what is below it, with
    /// what its .gitrepos lists (nothing if it has none). One that can't be
    /// read is a finding, and nothing below it is reported against it.
    private static EnclosingParent enclosingParentAt(string onDisk, string prefix, bool hasGitRepos,
        ref Finding[] findings)
    {
        import std.path : buildPath;

        bool[string] listed;
        if (hasGitRepos)
        {
            immutable path = buildPath(onDisk, ".gitrepos");
            try
            {
                foreach (gitReposEntry; new GitRepos(path).gitReposEntries)
                {
                    listed[gitReposEntry.directory] = true;
                }
            }
            catch (Exception exception) // GitReposException, UTFException or FileException
            {
                findings ~= Finding(prefix ~ "/", path ~ ": could not read it, so repositories below "
                    ~ onDisk ~ " were not checked against it (" ~ exception.msg ~ ")", false);
                return EnclosingParent(onDisk, prefix, false, listed, false);
            }
        }
        return EnclosingParent(onDisk, prefix, false, listed, true);
    }

    /// Adds to `named` what `onDisk`/.gitignore names. One that can't be
    /// read is a finding, and the directories it names are walked into.
    private static void addNamedIn(string onDisk, string prefix, ref bool[string] named,
        ref Finding[] findings)
    {
        import std.path : buildPath;
        import textFile : readIfExists, splitFileLines;

        immutable path = buildPath(onDisk, ".gitignore");
        try
        {
            bool endsWithNewline; // not needed
            addNamed(splitFileLines(readIfExists(path), endsWithNewline), prefix, named);
        }
        catch (Exception exception) // UTFException or FileException
        {
            findings ~= Finding(prefix ~ "/", path ~ ": could not read it, so the directories it names"
                ~ " were walked into (" ~ exception.msg ~ ")", false);
        }
    }

    /**
     * Whether `onDisk` is a nested repo, and if not, why: it must exist, be
     * a directory, and be the top level of its own git repository
     * (`git rev-parse --show-toplevel` succeeds and names it, compared after
     * resolving symlinks). `directory` is how messages name it. checkDisk()
     * and the commands all use this, so "is this a nested repo?" has one
     * answer.
     */
    static RepositoryResult checkRepository(string directory, string onDisk)
    {
        import std.file : exists, isDir;
        import std.process : execute;
        import std.string : strip;

        if (!onDisk.exists)
        {
            return RepositoryResult(RepositoryOutcome.missing, directory ~ " does not exist");
        }
        if (!onDisk.isDir)
        {
            return RepositoryResult(RepositoryOutcome.notDirectory, directory ~ " is not a directory");
        }
        const top = execute(["git", "-C", onDisk, "rev-parse", "--show-toplevel"]);
        if (top.status != 0)
        {
            return RepositoryResult(RepositoryOutcome.notGitRepository,
                directory ~ " is not a git repository (" ~ top.output.strip ~ ")");
        }
        if (resolvePath(top.output.strip) != resolvePath(onDisk))
        {
            return RepositoryResult(RepositoryOutcome.insideRepository,
                directory ~ " is inside the repository at " ~ top.output.strip
                ~ ", not a repository itself");
        }
        return RepositoryResult(RepositoryOutcome.repository, "");
    }

    /// Whether any remote of the repository at `onDisk` has `url` as its
    /// stored url (`remote.<name>.url`, before any insteadOf rewriting).
    private static bool hasRemoteUrl(string onDisk, string url)
    {
        import std.algorithm.searching : findSplit;
        import std.process : execute;
        import std.string : lineSplitter, strip;

        // Lines are "remote.<name>.url <url>"; exit status 1 just means
        // there are no remotes.
        const urls = execute(["git", "-C", onDisk, "config", "--get-regexp", `^remote\..*\.url$`]);
        foreach (line; urls.output.lineSplitter)
        {
            auto nameAndUrl = line.strip.findSplit(" ");
            if (nameAndUrl[1].length && nameAndUrl[2] == url)
            {
                return true;
            }
        }
        return false;
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
        foreach (gitReposEntry; _gitRepos.gitReposEntries)
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

        immutable before = _gitIgnore.before.filter!(line => keep(line)).array;
        immutable after = _gitIgnore.after.filter!(line => keep(line)).array;
        string[] nested = _gitIgnore.nested ~ moved ~ _gitRepos.gitReposEntries
            .filter!(gitReposEntry => !_gitIgnore.nested.canFind(gitReposEntry.directory))
            .map!(gitReposEntry => gitReposEntry.directory).array;

        _gitIgnore = new GitIgnore(_gitIgnore.path, before,
            GitIgnore.sortedUnique(nested), after, _gitIgnore.endsWithNewline);

        _gitRepos.gitReposEntries.sort!((left, right) => left.directory < right.directory, SwapStrategy.stable);

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
        _gitRepos.write();
        _gitIgnore.write();
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

/// checkRepository's five outcomes.
unittest
{
    import std.file : mkdir, write;

    immutable directory = testDirectory("parentDirectory-checkRepository");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    // outside: not in any repository; inside: a repository holding a plain folder.
    immutable outside = buildPath(directory, "outside");
    outside.mkdir;
    buildPath(outside, "file").write("not a directory\n");
    buildPath(outside, "plain").mkdir;
    git("init", "-q", buildPath(outside, "alpha"));
    immutable inside = buildPath(directory, "inside");
    git("init", "-q", inside);
    buildPath(inside, "folder").mkdir;

    RepositoryOutcome outcomeOf(string onDisk)
    {
        return ParentDirectory.checkRepository("/x/", onDisk).outcome;
    }

    assert(outcomeOf(buildPath(outside, "alpha")) == RepositoryOutcome.repository);
    assert(outcomeOf(buildPath(outside, "gone")) == RepositoryOutcome.missing);
    assert(outcomeOf(buildPath(outside, "file")) == RepositoryOutcome.notDirectory);
    assert(outcomeOf(buildPath(outside, "plain")) == RepositoryOutcome.notGitRepository);
    assert(outcomeOf(buildPath(inside, "folder")) == RepositoryOutcome.insideRepository);
    assert(ParentDirectory.checkRepository("/x/", buildPath(outside, "alpha")).message == "");
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

/// Item 6: a nested repo in the parent that .gitrepos doesn't list is
/// reported, unless a .gitignore line names it or its name starts with ".".
/// Symbolic links are followed; plain directories, files and dangling links
/// are not reported.
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.file : mkdir, symlink, write;
    import gitIgnore : beginMarker, endMarker;

    immutable directory = testDirectory("parentDirectory-disk-unlisted");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    // Repos the parent holds; parent is a plain directory, not a repository.
    immutable parent = buildPath(directory, "parent");
    git("init", "-q", buildPath(parent, "listed"));
    git("-C", buildPath(parent, "listed"), "remote", "add", "origin", "listed.git");
    git("init", "-q", buildPath(parent, "unlisted"));
    git("init", "-q", buildPath(parent, "outsideBlock")); // named by a hand-written line
    git("init", "-q", buildPath(parent, "insideBlock"));  // named by a block entry
    buildPath(parent, "plain").mkdir;
    buildPath(parent, "file").write("not a directory\n");
    git("init", "-q", buildPath(parent, ".hidden")); // dot-directories are skipped
    buildPath(parent, "nowhere").symlink(buildPath(parent, "dangling"));

    // A repo outside the parent, reached only through a link in it.
    immutable elsewhere = buildPath(directory, "elsewhere");
    git("init", "-q", elsewhere);
    elsewhere.symlink(buildPath(parent, "link"));

    buildPath(parent, ".gitignore").write("*.o\noutsideBlock/\n" ~ beginMarker
        ~ "\n/insideBlock/\n/listed/\n" ~ endMarker ~ "\n");
    buildPath(parent, ".gitrepos").write("/listed/ listed.git\n");

    const findings = new ParentDirectory(parent).checkDisk;
    assert(findings.map!(finding => finding.directory).array == ["/link/", "/unlisted/"]);
    // Neither has an origin remote, so neither is fixable (see the next test).
    assert(findings[1].message == buildPath(parent, "unlisted") ~ ": /unlisted/ is a git repository"
        ~ " but is not listed in " ~ buildPath(parent, ".gitrepos")
        ~ "; it has no origin remote, so add it with add-nested --url <url> unlisted");
    foreach (finding; findings)
    {
        assert(!finding.fixable);
    }
}

/// Item 6: fixable exactly when entryFor() works out the entry, and
/// registerUnlisted() registers those, in memory, as add-nested would:
/// origin's url, and the branch left out only by add-nested's rule.
unittest
{
    import std.algorithm.iteration : map;
    import std.algorithm.searching : canFind, endsWith;
    import std.array : array;
    import std.file : exists;
    import nestedCommon : makeRemote;

    immutable directory = testDirectory("parentDirectory-disk-unlisted-fixable");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    // The remote's default branch is main; it also has dev.
    immutable remote = makeRemote(directory, "alpha", "main", "dev");
    immutable parent = buildPath(directory, "parent");
    void cloneOn(string name, string branch)
    {
        immutable clone = buildPath(parent, name);
        git("clone", "-q", "-b", branch, remote, clone);
        // Set origin/HEAD explicitly rather than rely on clone doing it.
        git("-C", clone, "remote", "set-head", "origin", "main");
    }
    cloneOn("alpha", "main");    // named like the url, on the default: branch left out
    cloneOn("beta", "dev");      // another name and branch: branch recorded
    cloneOn("detached", "main"); // no current branch
    git("-C", buildPath(parent, "detached"), "checkout", "-q", "--detach");
    git("init", "-q", "-b", "main", buildPath(parent, "lonely")); // no origin
    git("init", "-q", "-b", "main", buildPath(parent, "odd"));    // a url .gitrepos refuses
    git("-C", buildPath(parent, "odd"), "remote", "add", "origin", "https://example.com//odd.git");

    auto parentDirectory = new ParentDirectory(parent);
    const findings = parentDirectory.checkDisk;
    assert(findings.map!(finding => finding.directory).array
        == ["/alpha/", "/beta/", "/detached/", "/lonely/", "/odd/"]);
    assert(findings.map!(finding => finding.fixable).array == [true, true, false, false, false]);
    assert(findings[0].message.endsWith(" is not listed in " ~ buildPath(parent, ".gitrepos")));
    assert(findings[2].message.endsWith("; it has no current branch (detached HEAD), so add it"
        ~ " with add-nested --branch <branch> detached"));
    assert(findings[3].message.endsWith("; it has no origin remote, so add it with add-nested --url <url> lonely"));
    assert(findings[4].message.canFind("; add-nested can't register it as it is: ")
        && findings[4].message.canFind("odd.git"));

    const gitReposEntries = parentDirectory.registerUnlisted();
    assert(gitReposEntries == [GitReposEntry("/alpha/", remote, ""), GitReposEntry("/beta/", remote, "dev")]);
    assert(parentDirectory.gitRepos.gitReposEntries == gitReposEntries); // both files, in step
    assert(parentDirectory.gitIgnore.nested == ["/alpha/", "/beta/"]);
    assert(!buildPath(parent, ".gitrepos").exists && !buildPath(parent, ".gitignore").exists);

    // Registered ones are no longer reported; the others still are.
    assert(parentDirectory.checkDisk.map!(finding => finding.directory).array
        == ["/detached/", "/lonely/", "/odd/"]);
    assert(parentDirectory.check.length == 0);
}

/// Item 6: a .gitignore line names a directory in any slash form, and only
/// a line that can name a directory (not a wildcard) keeps it quiet.
unittest
{
    import std.file : write;

    immutable directory = testDirectory("parentDirectory-disk-unlisted-named");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    git("init", "-q", buildPath(directory, "beta"));
    foreach (line; ["beta", "/beta", "beta/", "/beta/"])
    {
        buildPath(directory, ".gitignore").write(line ~ "\n");
        assert(new ParentDirectory(directory).checkDisk.length == 0, line);
    }
    foreach (line; ["bet*", "# beta", "!beta"])
    {
        buildPath(directory, ".gitignore").write(line ~ "\n");
        const findings = new ParentDirectory(directory).checkDisk;
        assert(findings.length == 1 && findings[0].directory == "/beta/", line);
    }
}

/// Item 6: a parent that doesn't exist has nothing to list, and no error.
unittest
{
    immutable directory = testDirectory("parentDirectory-disk-unlisted-gone");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    assert(new ParentDirectory(buildPath(directory, "gone")).checkDisk.length == 0);
}

// --- checkDisk(Yes.recursive): -r ------------------------------------------------

/// Item 6 with -r: the walk goes below the direct entries and into
/// repositories, skips dot-directories and what any .gitignore names
/// (nested ones too, each relative to its own folder), follows links
/// without looping, and judges each repository against its nearest
/// enclosing parent. Without -r, the same tree gives step 2's answer.
unittest
{
    import std.algorithm.iteration : filter, map;
    import std.algorithm.searching : endsWith;
    import std.array : array;
    import std.file : mkdirRecurse, symlink, write;
    import gitIgnore : beginMarker, endMarker;
    import nestedCommon : makeRemote;

    immutable directory = testDirectory("parentDirectory-disk-recursive");
    scope (exit)
    {
        directory.rmdirRecurse;
    }

    immutable remote = makeRemote(directory, "gamma", "main");
    void cloneTo(string clone)
    {
        git("clone", "-q", "-b", "main", remote, clone);
        // Set origin/HEAD explicitly rather than rely on clone doing it.
        git("-C", clone, "remote", "set-head", "origin", "main");
    }
    void initAt(string onDisk)
    {
        git("init", "-q", "-b", "main", onDisk); // no origin
    }

    immutable parent = buildPath(directory, "parent"); // a plain directory
    // listed: in .gitrepos and the block, so not walked into.
    initAt(buildPath(parent, "listed"));
    git("-C", buildPath(parent, "listed"), "remote", "add", "origin", "listed.git");
    initAt(buildPath(parent, "listed", "deep"));
    buildPath(parent, ".gitignore").write("*.o\n" ~ beginMarker ~ "\n/listed/\n" ~ endMarker ~ "\n");
    buildPath(parent, ".gitrepos").write("/listed/ listed.git\n");
    // A dot-directory, at the top and deeper: never walked into.
    initAt(buildPath(parent, ".cache", "hidden"));
    initAt(buildPath(parent, "tools", ".hidden", "repo"));
    // tools: a plain directory whose own .gitignore names "ignored"; a
    // wildcard line names nothing. gamma has an origin: fixable from here.
    cloneTo(buildPath(parent, "tools", "gamma"));
    initAt(buildPath(parent, "tools", "ignored"));
    initAt(buildPath(parent, "tools", "skipped"));
    buildPath(parent, "tools", ".gitignore").write("ignored\nskip*\n");
    parent.symlink(buildPath(parent, "tools", "loop")); // a link back to the top
    // outer: an unlisted repo, walked into. What is inside belongs to it.
    initAt(buildPath(parent, "outer"));
    initAt(buildPath(parent, "outer", "inner"));
    initAt(buildPath(parent, "outer", "sub", "deeper"));
    // research: a plain directory with its own .gitrepos, so the nearest
    // enclosing parent of what is below it. unlistedhere has an origin,
    // but still isn't fixable from the top.
    initAt(buildPath(parent, "research", "listedhere"));
    cloneTo(buildPath(parent, "research", "unlistedhere"));
    buildPath(parent, "research", ".gitrepos").write("/listedhere/ x.git\n");
    // link: a link to a plain directory elsewhere, holding a repo and a
    // link to itself.
    immutable elsewhere = buildPath(directory, "elsewhere");
    initAt(buildPath(elsewhere, "found"));
    elsewhere.symlink(buildPath(elsewhere, "back"));
    elsewhere.symlink(buildPath(parent, "link"));

    auto parentDirectory = new ParentDirectory(parent);
    const findings = parentDirectory.checkDisk(Yes.recursive);
    assert(findings.map!(finding => finding.directory).array == ["/link/found/", "/outer/",
        "/outer/inner/", "/outer/sub/deeper/", "/research/unlistedhere/", "/tools/gamma/",
        "/tools/skipped/"]);
    assert(findings.map!(finding => finding.fixable).array
        == [false, false, false, false, false, true, false]);

    // Its parent is the top: named relative to it, add-nested's hint as in step 2.
    assert(findings[0].message == buildPath(parent, "link", "found") ~ ": /link/found/ is a git"
        ~ " repository but is not listed in " ~ buildPath(parent, ".gitrepos")
        ~ "; it has no origin remote, so add it with add-nested --url <url> link/found");
    assert(findings[5].message == buildPath(parent, "tools", "gamma") ~ ": /tools/gamma/ is a git"
        ~ " repository but is not listed in " ~ buildPath(parent, ".gitrepos"));
    // Its parent is a repository, or a directory with a .gitrepos: named
    // relative to that parent, and how to fix it there; -r when it's deeper.
    assert(findings[2].message == buildPath(parent, "outer", "inner") ~ ": /inner/ is a git"
        ~ " repository but is not listed in " ~ buildPath(parent, "outer", ".gitrepos")
        ~ "; run check-nested -C " ~ buildPath(parent, "outer") ~ " --fix");
    assert(findings[3].message.endsWith(": /sub/deeper/ is a git repository but is not listed in "
        ~ buildPath(parent, "outer", ".gitrepos") ~ "; run check-nested -C "
        ~ buildPath(parent, "outer") ~ " -r --fix"));
    assert(findings[4].message == buildPath(parent, "research", "unlistedhere") ~ ": /unlistedhere/"
        ~ " is a git repository but is not listed in " ~ buildPath(parent, "research", ".gitrepos")
        ~ "; run check-nested -C " ~ buildPath(parent, "research") ~ " --fix");

    // Without -r: only the direct entries, exactly as in step 2.
    assert(parentDirectory.checkDisk.map!(finding => finding.directory).array == ["/outer/"]);
    assert(parentDirectory.registerUnlisted().length == 0); // outer has no origin

    // With -r, only the repo whose parent is the top is registered, and
    // after that it is named by the block, so no longer reported.
    assert(parentDirectory.registerUnlisted(Yes.recursive) == [GitReposEntry("/tools/gamma/", remote, "")]);
    assert(parentDirectory.gitIgnore.nested == ["/listed/", "/tools/gamma/"]);
    assert(parentDirectory.checkDisk(Yes.recursive).filter!(finding => finding.fixable).empty);
    assert(parentDirectory.checkDisk(Yes.recursive).map!(finding => finding.directory).array
        == ["/link/found/", "/outer/", "/outer/inner/", "/outer/sub/deeper/",
        "/research/unlistedhere/", "/tools/skipped/"]);
}

/// Item 6 with -r: a directory that can't be listed, and a nested
/// .gitrepos that can't be read, are findings; the walk goes on, and
/// nothing is reported against the .gitrepos it couldn't read.
unittest
{
    import std.algorithm.iteration : map;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.file : mkdirRecurse, setAttributes, write;
    import core.sys.posix.unistd : geteuid;
    import std.conv : octal;

    immutable directory = testDirectory("parentDirectory-disk-recursive-unreadable");
    immutable locked = buildPath(directory, "a-locked");
    locked.mkdirRecurse;
    git("init", "-q", "-b", "main", buildPath(locked, "inside"));
    locked.setAttributes(0); // no permission to list it
    scope (exit)
    {
        locked.setAttributes(octal!755); // so it can be removed
        directory.rmdirRecurse;
    }

    // b-broken's .gitrepos has an entry with no url, so it won't parse.
    git("init", "-q", "-b", "main", buildPath(directory, "b-broken", "below"));
    buildPath(directory, "b-broken", ".gitrepos").write("/below/\n");
    git("init", "-q", "-b", "main", buildPath(directory, "c-after")); // still reached

    const findings = new ParentDirectory(directory).checkDisk(Yes.recursive);
    if (geteuid() == 0)
    {
        return; // root can list a directory without permission; nothing to test
    }
    assert(findings.map!(finding => finding.directory).array == ["/a-locked/", "/b-broken/", "/c-after/"]);
    assert(findings[0].message.canFind(locked ~ ": could not list it to look for unlisted nested repos ("));
    assert(findings[1].message.canFind(buildPath(directory, "b-broken", ".gitrepos")
        ~ ": could not read it, so repositories below " ~ buildPath(directory, "b-broken")
        ~ " were not checked against it ("));
    foreach (finding; findings)
    {
        assert(!finding.fixable);
    }
}
