import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;

private bool isRepoUrl(string possibleRepoUrl);

private int addRepoToDesktop(string workingDirectoryNameOrRepoUrl) {
    // distinguish workingDirectoryName from RepoUrl
    if (workingDirectoryNameOrRepoUrl.isRepoUrl())
        return addRepoToDesktopFromRepoUrl(workingDirectoryNameOrRepoUrl);
    else
        return addRepoToDesktopFromWorkingDirectoryName(workingDirectoryNameOrRepoUrl);
}

private int addRepoToDesktopFromWorkingDirectoryName(string directoryName) {
    directoryName = directoryName.buildNormalizedPath(); // normalize the directory name

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

    debug writeln("if directoryName has no leading /, add it");
    if (!directoryName.startsWith("/"))
        directoryName = "/" ~ directoryName;

    debug writeln("if directoryName has no trailing /, add it");
    if (!directoryName.endsWith("/"))
        directoryName ~= "/";

    if (!"./.gitignore".exists)
         std.file.write("./.gitignore", "");;

    debug writeln("load .gitignore file");
    string[] gitIgnore = "./.gitignore".readText().splitLines;
    gitIgnore.sort;
    
    debug writeln("Does it already exist in .gitignore?");
    if (!gitIgnore.canFind(directoryName)) {
        debug writeln("no, add line like this in the correct alphabetic position in the file:");
        debug writeln("/directoryName/");
        gitIgnore.insertInPlace(gitIgnore.assumeSorted.lowerBound(directoryName).count, directoryName);
        debug writeln(gitIgnore);
        File file = "./.gitignore".File("wt");
        gitIgnore.each!(a => file.writeln(a));
        debug writeln("re-write .gitrepos");
    } else
        debug writeln("already in .gitignore");

    debug writeln("remove leading / from working directory");
    debug writeln("retrieve the \"origin\" remote from the working directory");
    auto retVal = executeShell("git -C " ~ directoryName[1..$] ~ " remote get-url origin");
    if (retVal.status != 0) {
        stderr.writeln("git did not run correctly: " ~ retVal.output);
        return 1;
    }
    
    debug writeln(retVal.output);
    string remoteUrl = retVal.output.strip;

    debug writeln("retrieve the active branch");
    retVal = executeShell("git -C " ~ directoryName[1..$] ~ " branch");
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
            string newValue = directoryName ~ " " ~ remoteUrl;
            if (activeBranch != "master" && activeBranch != "main")
                newValue = directoryName ~ " " ~ remoteUrl ~ " " ~ activeBranch;

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
        debug writeln("directoryName/ <remoteUrl>");
        if (activeBranch == "master" || activeBranch == "main")
            gitRepos.insertInPlace(gitRepos.assumeSorted.lowerBound(directoryName ~ " " ~ remoteUrl).count, directoryName ~ " " ~ remoteUrl);
        else
            gitRepos.insertInPlace(gitRepos.assumeSorted.lowerBound(directoryName ~ " " ~ remoteUrl).count, directoryName[] ~ " " ~ remoteUrl ~ " " ~ activeBranch);

        debug writeln(gitRepos);
        File file = "./.gitrepos".File("wt");
        gitRepos.each!(a => file.writeln(a));
        debug writeln("re-write .gitrepos");
    }

    return 0;
}

private int addRepoToDesktopFromRepoUrl(string repoUrl) {
    if (!theWorkingdirectoryPortionOfRepoUrlAlreadyExistsAsAWorkingDirectoryRelativeToPwd(repoUrl)) {
        stderr.writeln("The working directory portion of repoUrl doesn't already exist as a directory relative to pwd.");
        stderr.writeln("git clone repoUrl");
    }
    return 0;
}

private bool isRepoUrl(string possibleRepoUrl) {
    return possibleRepoUrl.indexOf(':') != -1;
}

int main(string[] args) {    
    if (args.length == 1) {
        stderr.writeln("add-nested repo-working-directory | remote-repo-url [...]");
        return 1;
    }
    
    int result = 0;
    for (int i = 1; i < args.length; i++) {
        if (addRepoToDesktop(args[i]))
            result = 1; // If any of the individual addRepoToDesktop() calls fails, the result will be be a failure.            
    }
    
    return result;
}

private bool theWorkingdirectoryPortionOfRepoUrlAlreadyExistsAsAWorkingDirectoryRelativeToPwd(string repoUrl) {
    return false;
}
