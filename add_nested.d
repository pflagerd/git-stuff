import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;

private bool isRepoURI(string possibleRepoURI);

private int addNestedRepo(string workingDirectoryNameOrRepoURI) {
    // distinguish workingDirectoryName from RepoURI
    if (workingDirectoryNameOrRepoURI.isRepoURI())
        return addNestedRepoFromRepoURIDirectoryName(workingDirectoryNameOrRepoURI);
    else
        return addNestedRepoFromDirectoryName(workingDirectoryNameOrRepoURI);
}

private int addNestedRepoFromDirectoryName(string directoryName) {
    directoryName = directoryName.buildNormalizedPath(); // normalize the directory name
    writeln(typeof(directoryName).stringof);

    try {
        if (!directoryName.isDir)
            throw new FileException(directoryName);
    } catch (FileException fe) {
        stderr.writeln(directoryName ~ " is not a directory. Cannot add repo.");
        return 1;
    }
    
    try {
        if (!(directoryName ~ "/.git").isDir)
            throw new FileException(directoryName);
    } catch (FileException fe) {
        stderr.writeln(directoryName ~ "/.git/ is not a directory or doesn't exist. Cannot add repo.");
        return 1;
    }

    debug writeln("if directoryName has a leading /, remove it");
    if (directoryName.startsWith("/"))
        directoryName = directoryName[1 .. $];
	debug writeln("directoryName = " ~ directoryName);

    debug writeln("if directoryName has no trailing /, add it");
    if (!directoryName.endsWith("/"))
        directoryName ~= "/";
	debug writeln("directoryName = " ~ directoryName);

    if (!"./.gitignore".exists)
         std.file.write("./.gitignore", "");;

    debug writeln("load .gitignore file");
    string[] gitIgnore = "./.gitignore".readText().splitLines;
    gitIgnore.sort;
    
    debug writeln("Does it already exist in .gitignore?");
    if (!gitIgnore.canFind("/" ~ directoryName)) {
        debug writeln("no, add line like this in the correct alphabetic position in the file: /" ~ directoryName);
        gitIgnore.insertInPlace(gitIgnore.assumeSorted.lowerBound("/" ~ directoryName).count, "/" ~ directoryName); // Add back leading / for .gitignore
        debug writeln(gitIgnore);
        File file = "./.gitignore".File("wt");
        gitIgnore.each!(a => file.writeln(a));
        debug writeln("re-write .gitignore");
    } else
        debug writeln("already in .gitignore");

    debug writeln("remove leading / from working directory");
    debug writeln("retrieve the \"origin\" remote from the working directory"); // the -C option accepts a directory with or without trailing /
    auto retVal = executeShell("git -C " ~ directoryName ~ " remote get-url origin");
    if (retVal.status != 0) {
        stderr.writeln("git did not run correctly: " ~ retVal.output);
        return 1;
    }
    
    string remoteURI = retVal.output.strip;

    debug writeln("retrieve the active branch");
    retVal = executeShell("git -C " ~ directoryName ~ " branch");
    if (retVal.status != 0) {
        stderr.writeln("git did not run correctly: " ~ retVal.output);
        return 1;
    }

    string activeBranch = "";
    debug writeln("retVal.output == " ~ retVal.output);
    string[] branches = retVal.output.splitLines;
    foreach (string branch; branches)
        if (branch.startsWith("*")) {
            activeBranch = branch.split(" ")[1];
            break;
        }

    if (!"./.gitrepos".exists)
        std.file.write("./.gitrepos", "");

    debug writeln("load .gitrepos file");
    string[] gitRepos = "./.gitrepos".readText().splitLines;
    gitRepos.sort;
    
    debug writeln("Does it already exist in .gitrepos?");
    bool found = false;
    for (int i = 0; i < gitRepos.length; i++) {
        if (gitRepos[i].startsWith(directoryName)) { // Found it
            found = true;
            debug writeln("Found " ~ gitRepos[i]);
            string newValue = directoryName ~ " " ~ remoteURI;
            if (activeBranch != "master" && activeBranch != "main")
                newValue = directoryName ~ " " ~ remoteURI ~ " " ~ activeBranch;

            if (gitRepos[i] != newValue) {
                debug writeln("Updating gitRepos[" ~ i.to!string ~ "] = " ~ newValue);
                gitRepos[i] = newValue;
            } else {
                debug writeln("gitRepos[" ~ i.to!string ~ "] value unchanged = " ~ newValue);
            }
            break;
        }
    }

    if (!found) {
        debug writeln("not found, add line like this in the correct alphabetic position in the file:");
        debug writeln("directoryName/ <remoteURI>");
        if (activeBranch == "master" || activeBranch == "main")
            gitRepos.insertInPlace(gitRepos.assumeSorted.lowerBound(directoryName ~ " " ~ remoteURI).count, directoryName ~ " " ~ remoteURI);
        else
            gitRepos.insertInPlace(gitRepos.assumeSorted.lowerBound(directoryName ~ " " ~ remoteURI).count, directoryName[] ~ " " ~ remoteURI ~ " " ~ activeBranch);

        debug writeln(gitRepos);
        File file = "./.gitrepos".File("wt");
        gitRepos.each!(a => file.writeln(a));
        debug writeln("re-write .gitrepos");
    }

    return 0;
}

private int addNestedRepoFromRepoURIDirectoryName(string repoURI) {
    if (!repoURIDirectoryNameAlreadyExistsAsGitDirectoryRelativeToPwd(repoURI)) {
        stderr.writeln("The working directory portion of repoURI doesn't already exist as a directory relative to pwd. Cannot add.");
        return 2;
    }

    return addNestedRepoFromDirectoryName(getDirectoryNamePortionOfRepoURI(repoURI));
}

private string getDirectoryNamePortionOfRepoURI(string repoURI) {
    int lastIndex = cast(int)repoURI.lastIndexOf('/');
    if (lastIndex == repoURI.length - 1) { // lastIndex is the last character in the string
        repoURI = repoURI[0 .. $ - 1];
        lastIndex = cast(int)repoURI.lastIndexOf('/');
    }
    if (lastIndex == -1)
        return "";
    return repoURI[lastIndex + 1 .. $];
}

private bool isRepoURI(string possibleRepoURI) {
    return possibleRepoURI.indexOf(':') != -1;
}

int main(string[] args) {    
    if (args.length == 1) {
        stderr.writeln("add-nested repo-directory ... ");
        stderr.writeln("  adds the repo-directory to .gitrepos and .gitignore");
        stderr.writeln("  includes the url and branch from the repo-directory unless the branch is master in which case the branch is left empty in .gitrepos");
        stderr.writeln("add-nested repo-url ... ");
        stderr.writeln("  adds the repo-url to .gitrepos and .gitignore. Uses the filename part of the url.");
        stderr.writeln("  assumes the master branch and doesn't include it in .gitrepos");

        return 1;
    }
    
    int result = 0;
    for (int i = 1; i < args.length; i++) {
        if (addNestedRepo(args[i]))
            result = 1; // If any of the individual addNestedRepo() calls fails, the result will be be a failure.
    }
    
    return result;
}

bool repoURIDirectoryNameAlreadyExistsAsGitDirectoryRelativeToPwd(string repoURI) {
    string directoryName = getDirectoryNamePortionOfRepoURI(repoURI);

    try {
        if (!directoryName.isDir)
            throw new FileException(directoryName);
    } catch (FileException fe) {
        stderr.writeln(directoryName ~ " is not a directory. Cannot add repo.");
        return false;
    }

    try {
        if (!(directoryName ~ "/.git").isDir)
            throw new FileException(directoryName);
    } catch (FileException fe) {
        stderr.writeln(directoryName ~ "/.git/ is not a directory or doesn't exist. Cannot add repo.");
        return false;
    }

    return true;
}
