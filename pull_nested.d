import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;
import std.utf;

import gitCloneDirectoryName : gitCloneDirectoryName;

static const auto gitrepos = ".gitrepos";

bool hasBranchNamed(string lines, string branch) {
	foreach (line; lines.lineSplitter()) {
		debug writeln(line);
		line = line[2..$];
		debug writeln(line);
		if (line.startsWith("remotes/origin/")) {
			line = line[15..$];
			debug writeln(line);
			if (line == branch)
				return true;
		} else {
			if (line == branch)
				return true;
		}
	}
	return false;
}

int main(string[] args) {
    if (!gitrepos.exists) {
		stderr.writeln(gitrepos ~ " does not exist in the current working directory. Cannot pull.");
		return 1;
	}

    debug writeln("load .gitrepos file");
    string[] gitRepos = "./.gitrepos".readText().splitLines;
    gitRepos.sort;
    auto retVal = 0;

    foreach (repo; gitRepos) {
		debug writeln("repo == \"" ~ repo ~ "\"");
		auto splitLine = repo.split();
		auto directoryName = splitLine[0];
	    debug writeln("if directory has a leading /, remove it: " ~ directoryName);
		if (directoryName.startsWith("/"))
			directoryName = directoryName[1..$];
	    debug writeln("if directory has a trailing /, remove it: " ~ directoryName);
		if (directoryName.endsWith("/"))
			directoryName = directoryName[0..$-1];

		writeln("directoryName == \"" ~ directoryName ~ "\"");
		writeln(typeof(directoryName).stringof);
		auto gitUrl = splitLine[1];
		writeln("gitUrl == \"" ~ gitUrl ~ "\"");
		auto gitDirectoryName = gitUrl.gitCloneDirectoryName;
		writeln("gitDirectoryName == \"" ~ gitDirectoryName ~ "\"");

		writefln("exists(%s) = %s, isDir would throw if false", directoryName, std.file.exists(directoryName));
		if (std.file.exists(directoryName)) {
			try {
				if (!directoryName.isDir())
					throw new FileException(directoryName);
			} catch (FileException fe) {
				stderr.writeln(directoryName ~ " is not a directory. Cannot clone or pull repo.");
				retVal = 2;
				continue;
			}

		    try {
				if (!(directoryName ~ "/.git").isDir)
					throw new FileException(directoryName);
			} catch (FileException fe) {
				stderr.writeln(directoryName ~ "/.git/ is not a directory. Cannot clone or pull repo.");
				retVal = 2;
				continue;
			}

			if (splitLine.length == 3 || directoryName != gitDirectoryName) {
				auto cmd1 = "git -C " ~ directoryName ~ " branch -a";
				debug cmd1.writeln();
				auto result = executeShell(cmd1);
				debug writeln("result.status = " ~ result.status.to!string ~ ", result.output = " ~ result.output);
				debug writeln(typeof(result.output).stringof);

				if (result.output.hasBranchNamed(directoryName) || (splitLine.length == 3 && result.output.hasBranchNamed(splitLine[2]))) {
					cmd1 = "git -C " ~ directoryName ~ " checkout " ~ (splitLine.length == 3 ? splitLine[2] : directoryName);
					debug cmd1.writeln();
					result = executeShell(cmd1);
					debug writeln("result.status = " ~ result.status.to!string ~ ", result.output = " ~ result.output);
				} else {
					if (splitLine.length == 3)
						stderr.writeln("Unable to find a branch named " ~ splitLine[2]);
					else
						stderr.writeln("Unable to find a branch named " ~ directoryName);
				}
			}

			auto cmd1 = "git -C " ~ directoryName ~ " pull";
			cmd1.writeln();
			auto result = executeShell(cmd1);
			result.output.write();
			continue;
		} else {
			auto cmd3 = "git clone " ~ gitUrl ~ " " ~ directoryName;
			writeln(cmd3);
			auto result = executeShell(cmd3);
			result.output.writeln();

			if (splitLine.length == 3 || directoryName != gitDirectoryName) {
				auto cmd4 = "git -C " ~ directoryName ~ " checkout " ~ (splitLine.length == 3 ? splitLine[2] : directoryName);
				writeln(cmd4);
				result = executeShell(cmd4);
				result.output.writeln();
			}
		}
	}

    return retVal;
}
